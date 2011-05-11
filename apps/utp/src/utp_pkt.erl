%% @doc Low level packet buffer management.
-module(utp_pkt).

-include("utp.hrl").

-export([
	 mk/0,
	 mk_buf/1,

         init_seqno/2,
         init_ackno/2,

	 packet_size/1,
	 mk_random_seq_no/0,
	 send_fin/2,
         send_ack/2,
         handle_send_ack/3,
	 handle_packet/5,
	 buffer_dequeue/1,
	 buffer_putback/2,
	 fill_window/4,

         advertised_window/1,
         handle_advertised_window/2,

         retransmit_packet/2,
         view_zero_window/1,
         bump_window/1,
         rto/1
	 ]).

%% DEFINES
%% ----------------------------------------------------------------------

%% The default RecvBuf size: 8K
-define(OPT_RECV_BUF, 8192).
-define(PACKET_SIZE, 350).
-define(REORDER_BUFFER_MAX_SIZE, 511).
-define(OUTGOING_BUFFER_MAX_SIZE, 511).
-define(OPT_SEND_BUF, ?OUTGOING_BUFFER_MAX_SIZE * ?PACKET_SIZE).

%% TYPES
%% ----------------------------------------------------------------------
-record(pkt_window, {
          %% Size of the window the Peer advertises to us.
	  peer_advertised_window = 4096 :: integer(),

	  %% The current window size in the send direction, in bytes.
	  cur_window :: integer(),
	  %% Maximal window size int the send direction, in bytes.
	  max_send_window :: integer(),

	  %% Timeouts,
	  %% --------------------
	  %% Set when we update the zero window to 0 so we can reset it to 1.
	  zero_window_timeout :: none | {set, reference()},
          rto = 3000 :: integer(), % Retransmit timeout default

	  %% Timestamps
	  %% --------------------
	  %% When was the window last totally full (in send direction)
	  last_maxed_out_window :: integer()
	 }).


-type t() :: #pkt_window{}.

-type message() :: send_ack.
-type messages() :: [message()].

-record(pkt_wrap, {
	  packet            :: utp_proto:packet(),
	  transmissions = 0 :: integer(),
	  need_resend = false :: boolean()
	 }).
-type pkt() :: #pkt_wrap{}.

-record(pkt_buf, {
          recv_buf    = queue:new()     :: queue(),
          reorder_buf = []              :: orddict:orddict(),
          %% When we have a working protocol, this retransmission queue is probably
          %% Optimization candidate 1 :)
          retransmission_queue = []     :: [#pkt_wrap{}],
          reorder_count = 0             :: integer(), % When and what to reorder
          next_expected_seq_no = 1      :: 0..16#FFFF, % Next expected packet
          seq_no = 1                    :: 0..16#FFFF, % Next Sequence number to use when sending

          %% Did we receive a fin packet?
          fin_state = none :: none | {got_fin, 0..16#FFFF},

          %% Packet buffer settings
          %% --------------------
          %% Size of the outgoing buffer on the socket
          opt_snd_buf_sz  = ?OPT_SEND_BUF :: integer(),
          %% Same, for the recv buffer
          opt_recv_buf_sz = ?OPT_RECV_BUF :: integer(),

	  %% The maximal size of packets.
          %% @todo Discover this one
	  pkt_size = 1000 :: integer()
         }).
-type buf() :: #pkt_buf{}.

%% Track send quota available
-record(send_quota, {
	  send_quota :: integer(),
	  last_send_quota :: integer()
	 }).
-type quota() :: #send_quota{}.

-export_type([t/0,
	      pkt/0,
	      buf/0,
              messages/0,
	      quota/0]).

%% API
%% ----------------------------------------------------------------------

%% PKT BUF INITIALIZATION
%% ----------------------------------------------------------------------
-spec mk() -> t().
mk() ->
    #pkt_window { }.

mk_buf(none)    -> #pkt_buf{};
mk_buf(OptRecv) ->
    #pkt_buf {
	opt_recv_buf_sz = OptRecv
       }.

init_seqno(#pkt_buf {} = PBuf, SeqNo) ->
    PBuf#pkt_buf { seq_no = SeqNo }.

init_ackno(#pkt_buf{} = PBuf, AckNo) ->
    PBuf#pkt_buf { next_expected_seq_no = AckNo }.

packet_size(_Socket) ->
    %% @todo FIX get_packet_size/1 to actually work!
    1000.

mk_random_seq_no() ->
    <<N:16/integer>> = crypto:rand_bytes(2),
    N.

%% Windows
%% ----------------------------------------------------------------------
handle_advertised_window(#packet { win_sz = Win }, PKW) ->
    handle_advertised_window(Win, PKW);
handle_advertised_window(NewWin, #pkt_window {} = PKWin) when is_integer(NewWin) ->
    PKWin#pkt_window { peer_advertised_window = NewWin }.

%% SEND SPECIFIC PACKET TYPES
%% ----------------------------------------------------------------------

%% @doc Toss out an ACK packet on the Socket.
%% @end
send_ack(SockInfo,
         #pkt_buf { seq_no = SeqNo,
                    next_expected_seq_no = AckNo
                  } = Buf) ->
    %% @todo Send out an ack message here
    AckPacket = #packet { ty = st_state,
                          seq_no = SeqNo-1, % @todo Is this right?
                          ack_no = AckNo-1, % We are recording the next expected ack number
                          extension = []
                        },
    Win = advertised_window(Buf),
    case utp_socket:send_pkt(Win, SockInfo, AckPacket) of
        ok ->
            ok;
        {error, Reason} ->
            error_logger:warning_report([dropping_packet, {error, Reason}]),
            ok
    end.

%% @doc Toss out a FIN packet on the Socket.
%% @todo Reconsider this. It may be it should be a normally streamed pkt
%%       rather than this variant where we send a special packet with
%%       FIN set.
%% @end
send_fin(SockInfo, Buf) ->
    send_packet(st_fin, <<>>, % Empty packet for now
                Buf, SockInfo).

send_packet(Bin, Buf, SockInfo) ->
    send_packet(st_data, Bin, Buf, SockInfo).

send_packet(Ty, Bin,
            #pkt_buf { seq_no = SeqNo,
                       next_expected_seq_no = AckNo,
                       retransmission_queue = RetransQueue } = Buf,
            SockInfo) ->
    P = #packet { ty = Ty,
                  seq_no  = SeqNo,
                  ack_no  = AckNo-1,
                  extension = [],
                  payload = Bin },
    Win = advertised_window(Buf),
    ok = utp_socket:send_pkt(Win, SockInfo, P),
    Wrap = #pkt_wrap { packet = P,
                       transmissions = 0,
                       need_resend = false },
    Buf#pkt_buf { seq_no = SeqNo+1,
                  retransmission_queue = [Wrap | RetransQueue]
                }.

%% @doc Consider if we should send out an ACK and do it if so
%% @end
handle_send_ack(SockInfo, PktBuf, Messages) ->
    case proplists:get_value(send_ack, Messages) of
        undefined ->
            ok;
        true ->
            send_ack(SockInfo, PktBuf)
    end.

%% RECEIVE PATH
%% ----------------------------------------------------------------------

%% @doc Given a Sequence Number in a packet, validate it
%% The `SeqNo' given is validated with respect to the current state of
%% the connection.
%% @end
validate_seq_no(SeqNo, PB) ->
    case bit16(SeqNo - PB#pkt_buf.next_expected_seq_no) of
        SeqAhead when SeqAhead >= ?REORDER_BUFFER_SIZE ->
            {error, is_far_in_future};
        SeqAhead ->
            {ok, SeqAhead}
    end.

%% @doc Assert that the current state is valid for Data packets
%% @end
-spec valid_state(atom()) -> ok.
valid_state(State) ->
    case State of
	connected -> ok;
	connected_full -> ok;
	fin_sent -> ok;
	_ -> throw({no_data, State})
    end.

%% @doc Consider if we should send out an ACK
%%   The Rule for ACK'ing is that the packet has altered the reorder buffer in any
%%   way for us. If the incoming packet has, we should let the other end know this.
%%   If the packet does not alter the reorder buffer however, we know it was either
%%   payload-less or duplicate (the latter is handled elsewhere). Payload-less packets
%%   are informational only, and if they generate ACK's it is not from this part of
%%   the code.
%% @end
consider_send_ack(#pkt_buf { reorder_buf = RB1,
                             next_expected_seq_no = Seq1 },
                  #pkt_buf { reorder_buf = RB2,
                             next_expected_seq_no = Seq2})
  when RB1 =/= RB2 orelse Seq1 =/= Seq2 ->
    [{send_ack, true}];
consider_send_ack(_, _) -> [].
       
%% @doc Update the receive buffer with Payload
%% This function will update the receive buffer with some incoming payload.
%% It will also return back to us a message if we should ack the incoming
%% packet. As such, this function wraps some lower-level operations,
%% with respect to incoming payload.
%% @end                      
-spec handle_receive_buffer(integer(), binary(), #pkt_buf{}, utp_gen_worker:conn_state()) ->
                                   {#pkt_buf{}, messages()}.
handle_receive_buffer(SeqNo, Payload, PacketBuffer, State) ->
    case update_recv_buffer(SeqNo, Payload, PacketBuffer, State) of
        %% Force an ACK out in this case
        duplicate -> {PacketBuffer, [{send_ack, true}]};
        #pkt_buf{} = PB -> {PB, consider_send_ack(PacketBuffer, PB)}
    end.


%% @doc Handle incoming Payload in datagrams
%% A Datagram came in with SeqNo and Payload. This Payload and SeqNo
%% updates the PacketBuffer if the SeqNo is valid for the current
%% state of the connection.
%% @end
handle_incoming_datagram_payload(SeqNo, Payload, PacketBuffer, State) ->
    %% We got a packet in with a seq_no and some things to ack.
    %% Validate the sequence number.
    case validate_seq_no(SeqNo, PacketBuffer) of
        {ok, _Num} ->
            ok;
        {error, Violation} ->
            throw({error, Violation})
    end,

    %% Handle the Payload by Dumping it into the packet buffer at the right point
    %% Returns a new PacketBuffer, and a list of Messages for the upper layer
    {_, _} = handle_receive_buffer(SeqNo, Payload, PacketBuffer, State).


%% @doc Update the Receive Buffer with Payload
%% There are essentially two cases: Either the packet is the next
%% packet in sequence, so we can simply push it directly to the
%% receive buffer right away. Then we can check the reorder buffer to
%% see if we can satisfy more packets from it. If it is not in
%% sequence, it should go into the reorder buffer in the right spot.
%% @end
update_recv_buffer(_SeqNo, <<>>, PB, _State) -> PB;
update_recv_buffer(SeqNo, Payload, #pkt_buf { next_expected_seq_no = SeqNo } = PB, State) ->
    %% This is the next expected packet, yay!
    error_logger:info_report([got_expected, SeqNo, bit16(SeqNo+1)]),
    N_PB =
        case State of
            fin_sent ->
                PB;
            connected ->
                enqueue_payload(Payload, PB)
        end,
    satisfy_from_reorder_buffer(
      N_PB#pkt_buf { next_expected_seq_no = bit16(SeqNo+1) }, State);
update_recv_buffer(SeqNo, Payload, PB, _State) when is_integer(SeqNo) ->
    reorder_buffer_in(SeqNo, Payload, PB).

%% @doc Try to satisfy the next_expected_seq_no directly from the reorder buffer.
%% @end
satisfy_from_reorder_buffer(#pkt_buf { reorder_buf = [] } = PB, _State) ->
    PB;
satisfy_from_reorder_buffer(#pkt_buf { next_expected_seq_no = AckNo,
				       reorder_buf = [{AckNo, PL} | R]} = PB,
                            State) ->
    N_PB =
        case State of
            fin_sent ->
                PB;
            connected ->
                enqueue_payload(PL, PB)
        end,
    satisfy_from_reorder_buffer(
      N_PB#pkt_buf { next_expected_seq_no = bit16(AckNo+1),
                     reorder_buf = R}, State);
satisfy_from_reorder_buffer(#pkt_buf { } = PB, _State) ->
    PB.

%% @doc Enter the packet into the reorder buffer, watching out for duplicates
%% @end
reorder_buffer_in(SeqNo, Payload, #pkt_buf { reorder_buf = OD } = PB) ->
    case orddict:is_key(SeqNo, OD) of
	true -> duplicate;
	false -> PB#pkt_buf { reorder_buf = orddict:store(SeqNo, Payload, OD) }
    end.

%% SEND PATH
%% ----------------------------------------------------------------------

update_send_buffer(AckNo, #pkt_buf { seq_no = BufSeqNo } = PB) ->
    WindowSize = send_window_count(PB),
    WindowStart = bit16(BufSeqNo - WindowSize),
    error_logger:info_report([window_is_at, WindowStart]),
    case view_ack_no(AckNo, WindowStart, WindowSize) of
        {ok, AcksAhead} ->
            {ok, Acked, PB1} = prune_acked(AcksAhead, WindowStart, PB),
            error_logger:info_report([{acks_ahead, AcksAhead},
                                      {acked, Acked}]),
            {ok, view_ack_state(Acked, PB1),
                 AcksAhead,
                 PB1};
        {ack_is_old, AcksAhead} ->
            error_logger:info_report([ack_is_old, AcksAhead]),
            {ok, [{old_ack, true}], 0, PB}
    end.

%% @doc Prune the retransmission queue for ACK'ed packets.
%% Prune out all packets from `WindowStart' and `AcksAhead' in. Return a new packet
%% buffer where the retransmission queue has been updated.
%% @todo All this AcksAhead business, why? We could as well just work directly on
%%       the ack_no I think.
%% @end
prune_acked(AckAhead, WindowStart,
            #pkt_buf { retransmission_queue = RQ } = PB) ->
    {AckedPs, N_RQ} = lists:partition(
                        fun(#pkt_wrap {
                               packet = #packet { seq_no = SeqNo } }) ->
                                Distance = bit16(SeqNo - WindowStart),
                                Distance =< AckAhead
                        end,
                        RQ),
    error_logger:info_report([pruned, length(AckedPs)]),
    {ok, length(AckedPs), PB#pkt_buf { retransmission_queue = N_RQ }}.

view_ack_state(0, _PB) ->
    [];
view_ack_state(N, PB) when is_integer(N) ->
    case has_inflight_data(PB) of
        true ->
            [{recv_ack, true}];
        false ->
            [{all_acked, true}]
    end.

-spec has_inflight_data(#pkt_buf{}) -> boolean().
has_inflight_data(#pkt_buf { retransmission_queue = [] }) -> false;
has_inflight_data(#pkt_buf { retransmission_queue = [_|_] }) -> true.

%% @doc View the state of the Ack
%% Given the `AckNo' and when the `WindowStart' started, we scrutinize the Ack
%% for correctness according to age. If the ACK is old, tell the caller.
%% @end
view_ack_no(AckNo, WindowStart, WindowSize) ->
    case bit16(AckNo - WindowStart) of
        N when N > WindowSize ->
            %% The ack number is old, so do essentially nothing in the next part
            {ack_is_old, N};
        N when is_integer(N) ->
            %% -1 here is needed because #pkt_buf.seq_no is one
            %% ahead It is the next packet to send out, so it
            %% is one beyond the top end of the window
            {ok, N}
    end.

send_window_count(#pkt_buf { retransmission_queue = RQ }) ->
    length(RQ).



%% INCOMING PACKETS
%% ----------------------------------------------------------------------

%% @doc Handle an incoming Packet
%% We proceed to handle an incoming packet by first seeing if it has
%% payload we are interested in, and if that payload advances our
%% buffers in any way. Then, afterwards, we handle the AckNo and
%% Advertised window of the packet to eventually send out more on the
%% socket towards the other end.
%% @end    
handle_packet(_CurrentTimeMs,
	      State,
	      #packet { seq_no = SeqNo,
			ack_no = AckNo,
			payload = Payload,
			win_sz  = WindowSize,
			ty = Type } = _Packet,
	      PktWindow,
	      PacketBuffer) when PktWindow =/= undefined ->
    %% Assert that we are currently in a state eligible for receiving
    %% datagrams of this type. This assertion ought not to be
    %% triggered by our code.
    ok = valid_state(State),

    %% Update the state by the receiving payload stuff.
    {N_PacketBuffer1, SendMessages} =
        handle_incoming_datagram_payload(SeqNo, Payload, PacketBuffer, State),

    %% The Packet may have ACK'ed stuff from our send buffer. Update
    %% the send buffer accordingly
    {ok, RecvMessages, _AcksAhead, N_PB1} =
        update_send_buffer(AckNo, N_PacketBuffer1),

    %% Some packets set a specific state we should handle in our end
    %% @todo This should probably happen earlier in the sequence.
    %% Can we right away ack the FIN? If yes, it should probably be done earlier
    N_PB2 = handle_packet_type(Type, SeqNo, N_PB1),

    {ok, N_PB2,
         handle_window_size(WindowSize, PktWindow),
         SendMessages ++ RecvMessages}.


handle_packet_type(Type, SeqNo, Buf) ->
    case Type of
        st_fin ->
            {Buf#pkt_buf { fin_state = {got_fin, SeqNo} }};
        st_data ->
            Buf;
        st_state ->
            Buf
    end.

handle_window_size(WindowSize, #pkt_window {} = PKI) ->
    PKI#pkt_window { peer_advertised_window = WindowSize }.

%% PACKET TRANSMISSION
%% ----------------------------------------------------------------------

%% @doc Build up a queue of payload to send
%% This function builds up to `N' packets to send out -- each packet up
%% to the packet size. The functions satisfies data from the
%% process_queue of processes waiting to get data sent. It returns an
%% updates ProcessQueue record and a `queue' of the packets that are
%% going out.
%% @end
fill_from_proc_queue(N, Buf, ProcQ) ->
    TxQ = queue:new(),
    fill_from_proc_queue(N, Buf#pkt_buf.pkt_size, TxQ, ProcQ).

%% @doc Worker for fill_from_proc_queue/3
%% @end
fill_from_proc_queue(0, _Sz, Q, Proc) ->
    {Q, Proc};
fill_from_proc_queue(N, MaxPktSz, Q, Proc) ->
    ToFill = case N =< MaxPktSz of
                 true -> N;
                 false -> MaxPktSz
             end,
    case utp_process:fill_via_send_queue(ToFill, Proc) of
        {filled, Bin, Proc1} ->
            fill_from_proc_queue(N - ToFill, MaxPktSz, queue:in(Bin, Q), Proc1);
        {partial, Bin, Proc1} ->
            {queue:in(Bin, Q), Proc1};
        zero ->
            {Q, Proc}
    end.

%% @doc Given a queue of things to send, transmit packets from it
%% @end
transmit_queue(Q, Buf, SockInfo) ->
    L = queue:to_list(Q),
    lists:foldl(fun(Data, B) ->
                        send_packet(Data, B, SockInfo)
                end,
                Buf,
                L).

%% @doc Fill up the Window with packets in the outgoing direction
%% @end
fill_window(SockInfo, ProcQueue, PktWindow, PktBuf) ->
    FreeInWindow = bytes_free_in_window(PktBuf, PktWindow),
    error_logger:info_report([free_in_window, FreeInWindow]),
    %% Fill a queue of stuff to transmit
    {TxQueue, NProcQueue} =
        fill_from_proc_queue(FreeInWindow, PktBuf, ProcQueue),

    %% Send out the queue of packets to transmit
    NBuf1 = transmit_queue(TxQueue, PktBuf, SockInfo),
    %% Eventually shove the Nagled packet in the tail
    {ok, NBuf1, NProcQueue}.

%% PACKET RETRANSMISSION
%% ----------------------------------------------------------------------

retransmit_packet(PktBuf, SockInfo) ->
    {Oldest, Rest} = pick_oldest_packet(PktBuf),
    #pkt_wrap { packet = Pkt,
                transmissions = N } = Oldest,
    Win = advertised_window(PktBuf),
    error_logger:info_report([resending, utp_socket:format_pkt(Pkt)]),
    ok = utp_socket:send_pkt(Win, SockInfo, Pkt),
    Wrap = Oldest#pkt_wrap { transmissions = N+1 },
    PktBuf#pkt_buf { retransmission_queue = [Wrap | Rest] }.

pick_oldest_packet(#pkt_buf { retransmission_queue = [Candidate | R] }) ->
    pick_oldest_packet(Candidate, R, []).

pick_oldest_packet(Candidate, [], Accum) ->
    {Candidate, lists:reverse(Accum)};
pick_oldest_packet(#pkt_wrap { packet = P1 } = C, [#pkt_wrap { packet = P2 } = W | R], Accum) ->
    case utp_socket:order_packets(P1, P2) of
        [P1, P2] ->
            pick_oldest_packet(C, R, [W | Accum]);
        [P2, P1] ->
            pick_oldest_packet(W, R, [C | Accum])
    end.

%% INTERNAL FUNCTIONS
%% ----------------------------------------------------------------------

%% @doc `bit16(Expr)' performs `Expr' modulo 65536
%% @end
bit16(N) ->
    N band 16#FFFF.

%% @doc Return the size of the receive buffer
%% @end
recv_buf_size(Q) ->
    L = queue:to_list(Q),
    lists:sum([byte_size(Payload) || Payload <- L]).

%% @doc Calculate the advertised window to use
%% @end
advertised_window(#pkt_buf { recv_buf = Q,
                             opt_recv_buf_sz = Sz }) ->
    FillValue = recv_buf_size(Q),
    case Sz - FillValue of
        N when N >= 0 ->
            N
    end.

payload_size(#pkt_wrap { packet = Packet }) ->
    byte_size(Packet#packet.payload).


view_inflight_bytes(#pkt_buf{ retransmission_queue = [] }) ->
    buffer_empty;
view_inflight_bytes(#pkt_buf{ retransmission_queue = Q }) ->
    case lists:sum([payload_size(Pkt) || Pkt <- Q]) of
        Sum when Sum >= ?OPT_SEND_BUF ->
            buffer_full;
        Sum ->
            {ok, Sum}
    end.

bytes_free_in_window(PktBuf, PktWindow) ->
    MaxSend = max_window_send(PktBuf, PktWindow),
    case view_inflight_bytes(PktBuf) of
        buffer_full ->
            0;
        buffer_empty ->
            MaxSend;
        {ok, Inflight} when Inflight =< MaxSend ->
            MaxSend - Inflight;
        {ok, _Inflight} ->
            0
    end.

max_window_send(#pkt_buf { opt_snd_buf_sz = SendBufSz },
                #pkt_window { peer_advertised_window = AdvertisedWindow,
                              max_send_window = MaxSendWindow }) ->
    lists:min([SendBufSz, AdvertisedWindow, MaxSendWindow]).


enqueue_payload(Payload, #pkt_buf { recv_buf = Q } = PB) ->
    PB#pkt_buf { recv_buf = queue:in(Payload, Q) }.

buffer_putback(B, #pkt_buf { recv_buf = Q } = Buf) ->
    Buf#pkt_buf { recv_buf = queue:in_r(B, Q) }.

buffer_dequeue(#pkt_buf { recv_buf = Q } = Buf) ->
    case queue:out(Q) of
	{{value, E}, Q1} ->
	    {ok, E, Buf#pkt_buf { recv_buf = Q1 }};
	{empty, _} ->
	    empty
    end.

view_zero_window(#pkt_window { peer_advertised_window = N }) when N > 0 ->
    ok; % There is no reason to update the window
view_zero_window(#pkt_window { peer_advertised_window = 0 }) ->
    zero.

bump_window(#pkt_window {} = Win) ->
    PacketSize = packet_size(todo),
    Win#pkt_window {
      peer_advertised_window = PacketSize
     }.

rto(#pkt_window { rto = RTO }) ->
    RTO.
