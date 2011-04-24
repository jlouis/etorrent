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
	 handle_packet/5,
	 buffer_dequeue/1,
	 buffer_putback/2,
	 fill_window/4,
	 zerowindow_timeout/2
	 ]).

-ifdef(NOT_BOUND).
-export([
	 can_write/6
	 ]).
-endif.

%% @todo Figure out when to stop ACK'ing packets.
%% @todo Implement when to stop ACK'ing packets.

%% DEFINES
%% ----------------------------------------------------------------------

%% The default RecvBuf size: 200K
-define(OPT_RECV_BUF, 200 * 1024).
-define(PACKET_SIZE, 350).
-define(OPT_SEND_BUF, ?OUTGOING_BUFFER_MAX_SIZE * ?PACKET_SIZE).
-define(ZERO_WINDOW_DELAY, 15*1000).

%% TYPES
%% ----------------------------------------------------------------------
-record(pkt_window, {
          %% This is set when the other end has fin'ed us
          fin_state = none :: none | {got_fin, 0..16#FFFF},

	  %% @todo: Consider renaming this to peer_advertised_window
	  peer_advertised_window :: integer(), % Called max_window_user in the libutp code

	  %% The current window size in the send direction, in bytes.
	  cur_window :: integer(),
	  %% Maximal window size int the send direction, in bytes.
	  max_send_window :: integer(),

	  %% Timeouts,
	  %% --------------------
	  %% Set when we update the zero window to 0 so we can reset it to 1.
	  zero_window_timeout :: none | {set, reference()},

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
          next_expected_seq_no = 0      :: 0..16#FFFF, % Next expected packet
          seq_no = 1                    :: 0..16#FFFF, % Next Sequence number to use when sending

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

max_window_send(#pkt_buf { opt_snd_buf_sz = SendBufSz },
                #pkt_window { peer_advertised_window = AdvertisedWindow,
                            max_send_window = MaxSendWindow }) ->
    lists:min([SendBufSz, AdvertisedWindow, MaxSendWindow]).


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

-ifdef(NOTUSED).
seqno(#pkt_wrap { packet = #packet { seq_no = S} }) ->
    S.
-endif().

packet_size(_Socket) ->
    %% @todo FIX get_packet_size/1 to actually work!
    1500.

mk_random_seq_no() ->
    <<N:16/integer>> = crypto:rand_bytes(2),
    N.

send_fin(SockInfo,
         #pkt_buf { seq_no = SeqNo,
                    next_expected_seq_no = AckNo }) ->
    %% @todo There is something with timers in the original code. Shouldn't be here, but in the
    %% caller, probably.
    FinPacket = #packet { ty = st_fin,
                          seq_no = SeqNo-1, % @todo Is this right?
                          ack_no = AckNo,
                          extension = []
                        },
    ok = utp_socket:send_pkt(SockInfo, FinPacket).

send_ack(SockInfo,
         #pkt_buf { seq_no = SeqNo,
                    next_expected_seq_no = AckNo
                  }  ) ->
    %% @todo Send out an ack message here
    AckPacket = #packet { ty = st_data,
                          seq_no = SeqNo-1, % @todo Is this right?
                          ack_no = AckNo,
                          extension = []
                        },
    ok = utp_socket:send_pkt(SockInfo, AckPacket).


bit16(N) ->
    N band 16#FFFF.

%% Given a Sequence Number in a packet, validate it
validate_seq_no(SeqNo, PB) ->
    case bit16(SeqNo - PB#pkt_buf.next_expected_seq_no) of
        SeqAhead when SeqAhead >= ?REORDER_BUFFER_SIZE ->
            {error, is_far_in_future};
        SeqAhead ->
            {ok, SeqAhead}
    end.

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
consider_send_ack(#pkt_buf { reorder_buf = RB1 },
                  #pkt_buf { reorder_buf = RB2 }) when RB1 == RB2 ->
    [send_ack];
consider_send_ack(_, _) -> [].
                             
-spec handle_receive_buffer(integer(), binary(), #pkt_buf{}) ->
                                   {#pkt_buf{}, messages()}.
handle_receive_buffer(SeqAhead, Payload, PacketBuffer) ->
    case update_recv_buffer(SeqAhead, Payload, PacketBuffer) of
        %% Force an ACK out in this case
        duplicate -> {PacketBuffer, [send_ack]};
        #pkt_buf{} = PB -> {PB, consider_send_ack(PacketBuffer, PB)}
    end.

handle_incoming_datagram_payload(SeqNo, Payload, PacketBuffer) ->
    %% We got a packet in with a seq_no and some things to ack.
    %% Validate the sequence number.
    SeqAhead =
        case validate_seq_no(SeqNo, PacketBuffer) of
            {ok, Num} ->
                Num;
            {error, Violation} ->
                throw({error, Violation})
        end,

    %% Handle the Payload by Dumping it into the packet buffer at the right point
    %% Returns a new PacketBuffer, and a list of Messages for the upper layer
    {_, _} = handle_receive_buffer(SeqAhead, Payload, PacketBuffer).
    
handle_packet(_CurrentTimeMs,
	      State,
	      #packet { seq_no = SeqNo,
			ack_no = AckNo,
			payload = Payload,
			win_sz  = WindowSize,
			ty = Type } = _Packet,
	      PktWindow,
	      PacketBuffer) when PktWindow =/= undefined ->
    %% Assert that we are currently in a state eligible for receiving datagrams
    %% of this type. This assertion ought not to be triggered by our code.
    ok = valid_state(State),

    %% Update the state by the receiving payload stuff.
    {N_PacketBuffer1, Messages1} =
        handle_incoming_datagram_payload(SeqNo, Payload, PacketBuffer),

    %% The Packet may have ACK'ed stuff from our send buffer. Update the send buffer accordingly
    {ok, AcksAhead, N_PB1} = update_send_buffer(AckNo, N_PacketBuffer1),

    %% Some packets set a specific state we should handle in our end
    {PKI, Messages} =
        case Type of
            st_fin ->
                PKW = PktWindow#pkt_window {
                        fin_state = {got_fin, SeqNo}
                       },
                ShouldDestroy =
                    handle_destroy_state_change(AcksAhead, N_PacketBuffer1),
                {PKW, [fin] ++ ShouldDestroy};
            st_data ->
                {PktWindow, []};
            st_state ->
                {PktWindow, [state_only]}
    end,
    {ok, N_PB1,
         handle_window_size(WindowSize, PKI),
         Messages ++ Messages1}.



handle_destroy_state_change(AckAhead, Buf) ->
    case send_window_count(Buf) == AckAhead of
        true -> [destroy];
        false -> []
    end.

handle_window_size(0, #pkt_window{} = PKI) ->
    TRef = erlang:send_after(?ZERO_WINDOW_DELAY, self(), zero_window_timeout),
    PKI#pkt_window { zero_window_timeout = {set, TRef},
		   peer_advertised_window = 0};
handle_window_size(WindowSize, #pkt_window {} = PKI) ->
    PKI#pkt_window { peer_advertised_window = WindowSize }.

handle_ack_no(AckNo, WindowStart, PacketBuffer) ->
    AckAhead = bit16(AckNo - WindowStart),
    %% @todo DANGER, send_window_count may be old and not used
    case AckAhead > send_window_count(PacketBuffer) of
        true ->
            %% The ack number is old, so do essentially nothing in the next part
            {ok, AckAhead, 0};
        false ->
            %% -1 here is needed because #pkt_buf.seq_no is one
            %% ahead It is the next packet to send out, so it
            %% is one beyond the top end of the window
            {ok, AckAhead, AckAhead - 1}
    end.

%% @todo the window packet size is probably wrong wrong wrong here
update_send_buffer(AckNo,
                   #pkt_buf { seq_no = BufSeqNo } = PB) ->
    WindowStart = bit16(BufSeqNo - send_window_count(PB)),
    {ok, AcksAhead, Acks} = handle_ack_no(AckNo, WindowStart, PB),
    {_Acked, PB1} = update_send_buffer1(Acks, WindowStart, PB),
    %% @todo SACK!
    {ok, AcksAhead, PB1}.


-ifdef(NOTUSED).
retransmit_q_find(_SeqNo, []) ->
    not_found;
retransmit_q_find(SeqNo, [PW|R]) ->
    case seqno(PW) == SeqNo of
	true ->
	    {value, PW};
	false ->
	    retransmit_q_find(SeqNo, R)
    end.
-endif().

update_send_buffer1(0, _WindowStart, PB) ->
    {0, PB}; %% Essentially a duplicate ACK, but we don't do anything about it
update_send_buffer1(AckAhead, WindowStart,
		   #pkt_buf { retransmission_queue = RQ } = PB) ->
    {AckedPackets, N_RQ} = lists:partition(
			     fun(#pkt_wrap {
				    packet = Pkt }) ->
				     SeqNo = Pkt#packet.seq_no,
				     Dist = bit16(SeqNo - WindowStart),
				     Dist =< AckAhead
			     end,
			     RQ),
    %% @todo This is a placeholder for later when we need LEDBAT congestion control
    _AckedBytes = sum_packets(AckedPackets),
    {length(AckedPackets), PB#pkt_buf { retransmission_queue = N_RQ }}.

sum_packets(List) ->
    Ps = [byte_size(Pkt#packet.payload) || #pkt_wrap { packet = Pkt } <- List],
    lists:sum(Ps).

update_recv_buffer(_SeqNo, <<>>, PB) -> PB;
update_recv_buffer(1, Payload, #pkt_buf { next_expected_seq_no = AckNo } = PB) ->
    %% This is the next expected packet, yay!
    N_PB = enqueue_payload(Payload, PB),
    satisfy_from_reorder_buffer(
      N_PB#pkt_buf { next_expected_seq_no = bit16(AckNo+1) });
update_recv_buffer(SeqNoAhead, Payload, PB) when is_integer(SeqNoAhead) ->
    reorder_buffer_in(SeqNoAhead , Payload, PB).

satisfy_from_reorder_buffer(#pkt_buf { reorder_buf = [] } = PB) ->
    PB;
satisfy_from_reorder_buffer(#pkt_buf { next_expected_seq_no = AckNo,
				       reorder_buf = [{SeqNo, PL} | R]} = PB) ->
    NextExpected = bit16(AckNo+1),
    case SeqNo == NextExpected of
	true ->
	    N_PB = enqueue_payload(PL, PB),
	    satisfy_from_reorder_buffer(
              N_PB#pkt_buf { next_expected_seq_no = SeqNo,
                             reorder_buf = R});
	false ->
	    PB
    end.

reorder_buffer_in(SeqNo, Payload, #pkt_buf { reorder_buf = OD } = PB) ->
    case orddict:is_key(SeqNo, OD) of
	true -> duplicate;
	false -> PB#pkt_buf { reorder_buf = orddict:store(SeqNo, Payload, OD) }
    end.

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


fill_packets(Bytes, Buf, ProcQ) ->
    TxQ = queue:new(),
    {TxQueue, ProcQ2} =  fill_from_proc_queue(Bytes,
                                              Buf#pkt_buf.pkt_size,
                                              TxQ,
                                              ProcQ),
    {TxQueue, ProcQ2}.

fill_from_proc_queue(0, _Sz, Q, Proc) ->
    {Q, Proc};
fill_from_proc_queue(N, Sz, Q, Proc) when Sz =< N ->
    case utp_process:fill_via_send_queue(Sz, Proc) of
        {filled, Bin, Proc1} ->
            fill_from_proc_queue(N - Sz, Sz, queue:in(Bin, Q), Proc1);
        {partial, Bin, Proc1} ->
            {queue:in(Bin, Q), Proc1}
    end.

transmit_packet(Bin,
                WindowSize,
                #pkt_buf { seq_no = SeqNo,
                           next_expected_seq_no = AckNo,
                           retransmission_queue = RetransQueue } = Buf,
                SockInfo) ->
    P = #packet { ty = st_data,
                  win_sz  = WindowSize,
                  seq_no  = SeqNo,
                  ack_no  = AckNo,
                  extension = [],
                  payload = Bin },
    ok = utp_socket:send_pkt(SockInfo, P),
    Wrap = #pkt_wrap { packet = P,
                       transmissions = 0,
                       need_resend = false },
    Buf#pkt_buf { seq_no = SeqNo+1,
                  retransmission_queue = [Wrap | RetransQueue]
                }.

transmit_queue(Q, WindowSize, Buf, SockInfo) ->
    {R, NQ} = queue:out(Q),
    case R of
        empty ->
            Buf;
        {value, Data} ->
            NewBuf = transmit_packet(Data, WindowSize, Buf, SockInfo),
            transmit_queue(NQ, WindowSize, NewBuf, SockInfo)
    end.

fill_window(SockInfo, ProcQueue, PktWindow, PktBuf) ->
    FreeInWindow = bytes_free(PktBuf, PktWindow),
    %% Fill a queue of stuff to transmit
    {TxQueue, NProcQueue} = fill_packets(FreeInWindow,
                                         PktBuf,
                                         ProcQueue),

    WindowSize = last_recv_window(PktBuf, NProcQueue),
    %% Send out the queue of packets to transmit
    NBuf1 = transmit_queue(TxQueue, WindowSize, PktBuf, SockInfo),
    %% Eventually shove the Nagled packet in the tail
    {ok, NBuf1, NProcQueue}.

last_recv_window(#pkt_buf { opt_recv_buf_sz = RSz },
                 ProcQueue) ->
    BufSize = utp_process:bytes_in_recv_buffer(ProcQueue),
    case RSz - BufSize of
        K when K > 0 -> K;
        _Otherwise   -> 0
    end.

zerowindow_timeout(TRef, #pkt_window { peer_advertised_window = 0,
                                     zero_window_timeout = {set, TRef}} = PKI) ->
                   PKI#pkt_window { peer_advertised_window = packet_size(PKI),
                                  zero_window_timeout = none };
zerowindow_timeout(TRef,  #pkt_window { zero_window_timeout = {set, TRef}} = PKI) ->
    PKI#pkt_window { zero_window_timeout = none };
zerowindow_timeout(_TRef,  #pkt_window { zero_window_timeout = {set, _TRef1}} = PKI) ->
    PKI.

bytes_free(PktBuf, PktWindow) ->
    MaxSend = max_window_send(PktBuf, PktWindow),
    case inflight_bytes(PktBuf) of
        buffer_full ->
            0;
        buffer_empty ->
            MaxSend;
        {ok, Inflight} when Inflight =< MaxSend ->
            MaxSend - Inflight;
        {ok, _Inflight} ->
            0
    end.

payload_size(#pkt_wrap { packet = Packet }) ->
    byte_size(Packet#packet.payload).

inflight_bytes(#pkt_buf{ retransmission_queue = [] }) ->
    buffer_empty;
inflight_bytes(#pkt_buf{ retransmission_queue = Q }) ->
    case lists:sum([payload_size(Pkt) || Pkt <- Q]) of
        Sum when Sum >= ?OUTGOING_BUFFER_MAX_SIZE - 1 ->
            buffer_full;
        Sum ->
            {ok, Sum}
    end.

send_window_count(#pkt_buf { retransmission_queue = RQ }) ->
    length(RQ).

