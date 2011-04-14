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
	 send_fin/1,
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
	  got_fin :: boolean(),
	  eof_pkt :: 0..16#FFFF, % The packet with the EOF flag

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
          ack_no = 0                    :: 0..16#FFFF, % Next expected packet
          seq_no = 1                    :: 0..16#FFFF, % Next Sequence number to use when sending
          last_ack = 0                  :: 0..16#FFFF, % Last ack the other end sent us
          %% Nagle
          send_nagle = none             :: none | {nagle, binary()},

          %% Windows
          %% --------------------
          %% Number of packets currently in the send window
          send_window_packets = 0       :: integer(),

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
    PBuf#pkt_buf { ack_no = AckNo }.

seqno(#pkt_wrap { packet = #packet { seq_no = S} }) ->
    S.

packet_size(_Socket) ->
    %% @todo FIX get_packet_size/1 to actually work!
    1500.

mk_random_seq_no() ->
    <<N:16/integer>> = crypto:rand_bytes(2),
    N.

send_fin(_SockInfo) ->
    %% @todo There is something with timers in the original code. Shouldn't be here, but in the
    %% caller, probably.
    todo.

send_ack(_SockInfo, Buf) ->
    %% @todo Send out an ack message here
    todo.

bit16(N) ->
    N band 16#FFFF.

handle_packet(_CurrentTimeMs,
	      State,
	      #packet { seq_no = SeqNo,
			ack_no = AckNo,
			payload = Payload,
			win_sz  = WindowSize,
			ty = Type } = _Packet,
	      PktWindow,
	      PacketBuffer) when PktWindow =/= undefined ->
    %% Assertions
    %% ------------------------------
    SeqAhead = bit16(SeqNo - PacketBuffer#pkt_buf.ack_no),
    if
	SeqAhead >= ?REORDER_BUFFER_SIZE ->
	    %% Packet looong into the future, ignore
	    throw({invalid, is_far_in_future});
	true ->
	    %% Packet ok, feed to rest of system
	    ok
    end,
    case State of
	connected -> ok;
	connected_full -> ok;
	fin_sent -> ok;
	_ -> throw({no_data, State})
    end,
    %% State update
    %% ------------------------------
    {FinState, N_PKI} = handle_fin(Type, SeqNo, PktWindow),
    N_PB = case update_recv_buffer(SeqAhead, Payload, PacketBuffer) of
	       duplicate -> PacketBuffer; % Perhaps do something else here
	       #pkt_buf{} = PB -> PB
	   end,
    WindowStart = bit16(PacketBuffer#pkt_buf.seq_no
			- PacketBuffer#pkt_buf.send_window_packets),
    AckAhead = bit16(AckNo - WindowStart),
    Acks = if
	       AckAhead > PacketBuffer#pkt_buf.send_window_packets ->
		   0; % The ack number is old, so do essentially nothing in the next part
	       true ->
		   %% -1 here is needed because #pkt_buf.seq_no is one
		   %% ahead It is the next packet to send out, so it
		   %% is one beyond the top end of the window
		   AckAhead -1
	   end,
    N_PB1 = update_send_buffer(Acks, WindowStart, N_PB),
    N_PKI1 = handle_window_size(WindowSize, N_PKI),
    DestroyState = if
		       %% @todo send_window_packets right?
		       AckAhead == N_PB1#pkt_buf.send_window_packets
		         andalso State == fin_sent ->
			   [destroy];
		       true ->
			   []
		   end,
    NagleState = consider_nagle(N_PB1),
    {ok, N_PB1#pkt_buf { last_ack = AckNo },
         N_PKI1, FinState ++ DestroyState ++ NagleState}.

handle_fin(st_fin, SeqNo, #pkt_window { got_fin = false } = PKI) ->
    {[fin], PKI#pkt_window { got_fin = true,
			   eof_pkt = SeqNo }};
handle_fin(_, _, PKI) -> {[], PKI}.

handle_window_size(0, #pkt_window{} = PKI) ->
    TRef = erlang:send_after(?ZERO_WINDOW_DELAY, self(), zero_window_timeout),
    PKI#pkt_window { zero_window_timeout = {set, TRef},
		   peer_advertised_window = 0};
handle_window_size(WindowSize, #pkt_window {} = PKI) ->
    PKI#pkt_window { peer_advertised_window = WindowSize }.

update_send_buffer(AcksAhead, WindowStart, PB) ->
    {Acked, PB} = update_send_buffer1(AcksAhead, WindowStart, PB),
    %% @todo SACK!
    PB#pkt_buf { send_window_packets = PB#pkt_buf.send_window_packets - Acked }.

retransmit_q_find(_SeqNo, []) ->
    not_found;
retransmit_q_find(SeqNo, [PW|R]) ->
    case seqno(PW) == SeqNo of
	true ->
	    {value, PW};
	false ->
	    retransmit_q_find(SeqNo, R)
    end.


%% @todo I don't like this code that much. It is keyed on a lot of crap which I am
%% not sure I am going to maintain in the long run.
consider_nagle(#pkt_buf { send_window_packets = 1,
			  seq_no = SeqNo,
			  retransmission_queue = RQ,
			  reorder_count = ReorderCount
			  }) ->
    {value, PktW} = retransmit_q_find(SeqNo-1, RQ),
    case PktW#pkt_wrap.transmissions of
	0 ->
	    case ReorderCount of
		0 ->
		    [send_ack, sent_ack];
		_ ->
		    [send_ack]
	    end;
	_ ->
	    []
    end;
consider_nagle(#pkt_buf {}) -> [].


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
update_recv_buffer(1, Payload, #pkt_buf { ack_no = AckNo } = PB) ->
    %% This is the next expected packet, yay!
    N_PB = enqueue_payload(Payload, PB),
    satisfy_from_reorder_buffer(N_PB#pkt_buf { ack_no = bit16(AckNo+1) });
update_recv_buffer(SeqNoAhead, Payload, PB) when is_integer(SeqNoAhead) ->
    reorder_buffer_in(SeqNoAhead , Payload, PB).

satisfy_from_reorder_buffer(#pkt_buf { reorder_buf = [] } = PB) ->
    PB;
satisfy_from_reorder_buffer(#pkt_buf { ack_no = AckNo,
				       reorder_buf = [{SeqNo, PL} | R]} = PB) ->
    NextExpected = bit16(AckNo+1),
    case SeqNo == NextExpected of
	true ->
	    N_PB = enqueue_payload(PL, PB),
	    satisfy_from_reorder_buffer(N_PB#pkt_buf { ack_no = SeqNo, reorder_buf = R});
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


fill_nagle(0, Q, Buf, Proc) ->
    {0, Q, Buf, Proc};
fill_nagle(N, Q, #pkt_buf { send_nagle = none } = Buf, Proc) ->
    {N, Q, Buf, Proc}; % No nagle, skip
fill_nagle(N, Q, #pkt_buf { send_nagle = {nagle, NagleBin},
                            pkt_size = Sz} = Buf, Proc) ->
    K = byte_size(NagleBin),
    true = K < Sz,
    Space = Sz - K,
    ToFill = lists:min([Space, N]),
    case utp_process:fill_via_send_queue(ToFill, Proc) of
        {filled, Bin, Proc1} ->
            {N - ToFill, queue:in(<<NagleBin/binary, Bin/binary>>, Q),
             Buf #pkt_buf { send_nagle = none }, Proc1};
        {partial, Bin, Proc1} ->
            {0, Q, Buf#pkt_buf { send_nagle = {nagle, <<NagleBin/binary, Bin/binary>>}}, Proc1}
    end.

fill_packets(Bytes, Buf, ProcQ) ->
    Q = queue:new(),
    {BytesAfterNagle, TxQ, NBuf, NProcQ} = fill_nagle(Bytes, Q, Buf, ProcQ),
    {TxQueue, ProcQ2} =  fill_from_proc_queue(BytesAfterNagle,
                                              NBuf#pkt_buf.pkt_size,
                                              TxQ,
                                              NProcQ),
    {TxQueue, ProcQ2, NBuf}.

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
                           ack_no = AckNo,
                           retransmission_queue = RetransQueue } = Buf,
                SockInfo) ->
    P = #packet { ty = st_data,
                  conn_id = utp_socket:conn_id(SockInfo),
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

transmit_queue(Q, WindowSize, #pkt_buf { pkt_size = Sz,
                                         retransmission_queue = RQ } = Buf, SockInfo) ->
    {R, NQ} = queue:out(Q),
    case R of
        empty ->
            Buf;
        {value, Data} when byte_size(Data) < Sz ->
            case RQ of
                [] ->
                    NewBuf = transmit_packet(Data, WindowSize, Buf, SockInfo),
                    transmit_queue(NQ, WindowSize, NewBuf, SockInfo);
                L when is_list(L) ->
                    true = queue:is_empty(NQ),
                    Buf#pkt_buf { send_nagle = {nagle, Data}}
            end;
        {value, Data} when byte_size(Data) == Sz ->
            NewBuf = transmit_packet(Data, WindowSize, Buf, SockInfo),
            transmit_queue(NQ, WindowSize, NewBuf, SockInfo)
    end.

view_nagle_transmit(#pkt_buf { send_nagle = none }) ->
    no;
view_nagle_transmit(#pkt_buf { retransmission_queue = [], send_nagle = {nagle, Bin} } = Buf) ->
    {yes, Bin, Buf#pkt_buf { send_nagle = none }};
view_nagle_transmit(#pkt_buf { retransmission_queue = _, send_nagle = {nagle, _} }) ->
    no.



fill_window(SockInfo, ProcQueue, PktWindow, PktBuf) ->
    FreeInWindow = bytes_free(PktBuf, PktWindow),
    %% Fill a queue of stuff to transmit
    {TxQueue, NProcQueue, NBuf} = fill_packets(FreeInWindow,
                                         PktBuf,
                                         ProcQueue),

    WindowSize = last_recv_window(NBuf, NProcQueue),
    %% Send out the queue of packets to transmit
    NBuf1 = transmit_queue(TxQueue, WindowSize, NBuf, SockInfo),
    %% Eventually shove the Nagled packet in the tail
    case view_nagle_transmit(NBuf1) of
        no ->
            {ok, NBuf1, NProcQueue};
        {yes, Bin, NBuf2} ->
            Buf = transmit_packet(Bin, WindowSize, NBuf2, SockInfo),
            {ok, Buf, NProcQueue}
    end.

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

inflight_bytes(#pkt_buf{ retransmission_queue = [],
                           send_nagle = none }) ->
    buffer_empty;
inflight_bytes(#pkt_buf{ retransmission_queue = [],
                           send_nagle = {nagle, Bin}}) ->
    {ok, byte_size(Bin)};
inflight_bytes(#pkt_buf{ retransmission_queue = Q,
                           send_nagle = N }) ->
    Nagle = case N of
                none -> 0;
                {nagle, Bin} -> byte_size(Bin)
            end,
    case lists:sum([payload_size(Pkt) || Pkt <- Q]) + Nagle of
        Sum when Sum >= ?OUTGOING_BUFFER_MAX_SIZE - 1 ->
            buffer_full;
        Sum ->
            {ok, Sum}
    end.

-ifdef(NOT_BOUND).

%% We don't need this function at all. There is so much wrong about it...
can_write(CurrentTime, Size, PacketSize, CurrentWindow,
	  #pkt_buf { send_max_window = SendMaxWindow,
		     send_window_packets = SendWindowPackets,
		     opt_snd_buf_sz  = OptSndBuf,
		     max_window      = MaxWindow },
	  PKI) ->
    %% We can't send more than what one of the windows will bound us by.
    %% So the max send value is the minimum over these:
    MaxSend = lists:min([MaxWindow, OptSndBuf, SendMaxWindow]),
    Res = if
	      SendWindowPackets >= ?OUTGOING_BUFFER_MAX_SIZE-1 ->
		  false;
	      SendWindowPackets + PacketSize =< MaxSend ->
		  true;
	      MaxWindow < Size
	        andalso CurrentWindow < MaxWindow
	        andalso SendWindowPackets == 0 ->
		  true;
	      true ->
		  false
	  end,
    %% @todo quota
    %% @todo Why the heck do we have this side-effect here? The last_maxed_out_window
    %% should be set in other ways I think. It has nothing to do with the question of
    %% we can write on the socket or not!
    PacketExceed = CurrentWindow + PacketSize >= MaxWindow,
    {Res, PKI#pkt_window {
	    last_maxed_out_window =
		case PacketExceed of
		    true ->
			CurrentTime;
		    false ->
			PKI#pkt_window.last_maxed_out_window
	       end
	  }}.
-endif.





