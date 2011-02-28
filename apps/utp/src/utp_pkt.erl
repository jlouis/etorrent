%% @doc Low level packet buffer management.
-module(utp_pkt).

-include("utp.hrl").

-export([
	 mk/0,
	 packet_size/1,
	 rcv_window/0,
	 mk_random_seq_no/0,
	 send_fin/1,
	 handle_packet/5,
	 buffer_dequeue/1,
	 buffer_putback/2,
	 fill_window/5
	 ]).

-export([
	 can_write/6
	 ]).

%% TYPES
%% ----------------------------------------------------------------------
-record(pkt_info, {
	  got_fin :: boolean(),
	  eof_pkt :: 0..16#FFFF, % The packet with the EOF flag
	  max_window_user :: integer(), % The maximal window size we have

	  pkt_size :: integer(), % The maximal size of packets
	  cur_window :: integer(), % Current send window size

	  %% Timeouts,
	  %%   Set when we update the zero window to 0 so we can reset it to 1.
	  zero_window_timeout :: none | {set, reference()},

	  %% Timestamps
	  last_maxed_out_window :: integer(),

	  opt_sendbuf    :: integer() }).

-type t() :: #pkt_info{}.


-record(pkt_wrap, {
	  packet            :: utp_proto:packet(),
	  transmissions = 0 :: integer(),
	  need_resend = false :: integer()
	 }).
-type pkt() :: #pkt_wrap{}.

-record(pkt_buf, { recv_buf :: queue(),
		   reorder_buf = [] :: orddict:orddict(),
		   %% When we have a working protocol, this retransmission queue is probably
		   %% Optimization candidate 1 :)
		   retransmission_queue = [] :: [#pkt_wrap{}],
		   reorder_count             :: integer(), % When and what to reorder
		   send_window_packets :: integer(), % Number of packets currently in the send window
		   ack_no   :: 0..16#FFFF, % Next expected packet
		   seq_no   :: 0..16#FFFF, % Next Sequence number to use when sending packets
		   last_ack :: 0..16#FFFF, % Last ack the other end sent us
		   %% Nagle
		   send_nagle    :: none | {nagle, binary()},

		   send_max_window :: integer(),
		   max_window      :: integer(),
		   opt_snd_buf     :: integer()
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

%% DEFINES
%% ----------------------------------------------------------------------

%% The default RecvBuf size: 200K
-define(OPT_RCVBUF, 200 * 1024).
-define(ZERO_WINDOW_DELAY, 15*1000).

%% API
%% ----------------------------------------------------------------------

-spec mk() -> t().
mk() ->
    #pkt_info { }.


seqno(#packet { seq_no = S}) ->
    S;
seqno(#pkt_wrap { packet = #packet { seq_no = S} }) -> S.


packet_size(_Socket) ->
    %% @todo FIX get_packet_size/1 to actually work!
    1500.

mk_random_seq_no() ->
    <<N:16/integer>> = crypto:random_bytes(2),
    N.

rcv_window() ->
    %% @todo, trim down if receive buffer is present!
    ?OPT_RCVBUF.

send_fin(_SockInfo) ->
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
	      PktInfo,
	      PacketBuffer) ->
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
    {FinState, N_PKI} = handle_fin(Type, SeqNo, PktInfo),
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

handle_fin(st_fin, SeqNo, #pkt_info { got_fin = false } = PKI) ->
    {[fin], PKI#pkt_info { got_fin = true,
			   eof_pkt = SeqNo }};
handle_fin(_, _, PKI) -> {[], PKI}.

handle_window_size(0, PKI) ->
    TRef = erlang:send_after(?ZERO_WINDOW_DELAY, self(), zero_window_timeout),
    PKI#pkt_info { zero_window_timeout = {set, TRef},
		   max_window_user = 0};
handle_window_size(WindowSize, PKI) ->
    PKI#pkt_info { max_window_user = WindowSize }.

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

consider_nagle(#pkt_buf { send_window_packets = 1,
			  seq_no = SeqNo,
			  retransmission_queue = RQ,
			  reorder_count = ReorderCount
			  }) ->
    {ok, PktW} = retransmit_q_find(SeqNo-1, RQ),
    case PktW#pkt_wrap.transmissions of
	0 ->
	    case ReorderCount of
		0 ->
		    [send_ack, sent_ack];
		_ ->
		    []
	    end;
	_ ->
	    []
    end.

update_send_buffer1(0, _WindowStart, PB) ->
    PB; %% Essentially a duplicate ACK, but we don't do anything about it
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
    case orddict:is_key(SeqNo) of
	true ->
	    duplicate;
	false ->
	    PB#pkt_buf { reorder_buf = orddict:store(SeqNo, Payload, OD) }
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

can_write(CurrentTime, Size, PacketSize, CurrentWindow,
	  #pkt_buf { send_max_window = SendMaxWindow,
		     send_window_packets = SendWindowPackets,
		     opt_snd_buf    = OptSndBuf,
		     max_window      = MaxWindow },
	  PKI) ->
    %% We can't send more than what one of the windows will bound is by.
    %% So the max send value is the minimum over these:
    MaxSend = lists:min([MaxWindow, OptSndBuf, SendMaxWindow]),
    PacketExceed = CurrentWindow + PacketSize >= MaxWindow,
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
    %% @todo
    {Res, PKI#pkt_info {
	    last_maxed_out_window =
		case PacketExceed of
		    true ->
			CurrentTime;
		    false ->
			PKI#pkt_info.last_maxed_out_window
	       end
	  }}.

fill_window(ConnId, SockInfo, ProcInfo, PktInfo, PktBuf) ->
    PacketsToTransmit = packets_to_transmit(PktInfo#pkt_info.pkt_size, PktBuf),
    {ok, Packets, ProcInfo1} = dequeue_packets(PacketsToTransmit,
					       ProcInfo, [],
					       PktInfo#pkt_info.pkt_size),
    {ok, PKB1, PktWrap} = mk_packets(Packets, PktInfo#pkt_info.pkt_size, PktBuf, []),
    {ok, FilledPackets} = transmit_packets(PktWrap, PktInfo, SockInfo, ConnId, []),
    PKB2 = enqueue_packets(FilledPackets, PKB1),
    {ok, PKB2, ProcInfo1}.

enqueue_packets(Packets, #pkt_buf { retransmission_queue = RQ } = PacketBuf) ->
    PacketBuf#pkt_buf { retransmission_queue = Packets ++ RQ }.

send_packet(SI, FilledPkt) ->
    gen_utp_worker:send_pkt(SI, FilledPkt).

transmit_packets([], _, _, _, Acc) ->
    lists:reverse(Acc);
transmit_packets([#pkt_wrap {
		     packet = Pkt,
		     transmissions = 0,
		     need_resend = false } | Rest], PKI, SI, ConnId, Acc) ->
    FilledPkt = Pkt#packet {
		  conn_id = ConnId,
		  win_sz  = PKI#pkt_info.cur_window },
    send_packet(SI, FilledPkt),
    transmit_packets(Rest, PKI, SI, ConnId, [FilledPkt | Acc]).

packets_to_transmit(PacketSize,
		    #pkt_buf { send_window_packets = N,
			       send_nagle = Nagle } = PktBuf) ->
    Window = send_window(PktBuf),
    if
	Window < N ->
	    case Nagle of
		none ->
		    [{full, N - Window}];
		{nagle, _TRef, Bin} ->
		    [{partial, PacketSize - byte_size(Bin)}, {full, N - (Window + 1)}]
	    end;
	Window == N ->
	    []
    end.

dequeue_packets([], PI, Acc, _PacketSize) ->
    {ok, lists:reverse(Acc), PI};
dequeue_packets([{partial, Sz} | R], PI, Acc, PacketSize) ->
    dequeue_packets1(Sz, PI, Acc, R, partial, PacketSize);
dequeue_packets([{full, 0}], PI, Acc, PacketSize) ->
    dequeue_packets([], PI, Acc, PacketSize);
dequeue_packets([{full, N} | R], PI, Acc, PacketSize) ->
    dequeue_packets1(PacketSize, PI, Acc, [{full, N-1} | R], full, PacketSize).

dequeue_packets1(Sz, PI, Acc, R, Ty, PSz) ->
    case utp_process:dequeue_packet(PI, Sz) of
	none ->
	    dequeue_packets([], PI, Acc, PSz);
	{value, Bin, PI1} when byte_size(Bin) == Sz ->
	    dequeue_packets(R, PI1, [{Ty, Bin} | Acc], PSz);
	{value, Bin, PI1} when byte_size(Bin) < Sz ->
	    dequeue_packets(R, PI1, [{nagle, Bin} | Acc], PSz)
    end.


mk_packets([], _PSz, PKB, Acc) ->
    {ok, PKB, lists:reverse(Acc)};
mk_packets([{partial, Bin} | Rest], PSz,
		 #pkt_buf { send_nagle = {nagle, NBin}} = PKB, Acc) ->
    PSz = byte_size(Bin) + byte_size(NBin),
    mk_packets([{full, <<Bin/binary, NBin/binary>>} | Rest],
		     PSz,
		     PKB#pkt_buf { send_nagle = none }, Acc);
mk_packets([{full, Bin} | Rest], PSz,
		 #pkt_buf { seq_no = SeqNo } = PKB, Acc) ->
    Pkt = mk_pkt(Bin, PKB#pkt_buf.seq_no+1, PKB#pkt_buf.last_ack),
    mk_packets(Rest, PSz, PKB#pkt_buf { seq_no = SeqNo+1 }, [Pkt | Acc]);
mk_packets([{nagle, Bin}], PSz,
 		 #pkt_buf { send_nagle = {nagle, NBin} } = PKB, Acc) ->
     mk_packets([], PSz,
 		     PKB#pkt_buf {
 		       send_nagle = {nagle, <<NBin/binary, Bin/binary>>}}, Acc);
mk_packets([{nagle, Bin}], PSz,
 		 #pkt_buf { send_nagle = none } = PKB, Acc) ->
     mk_packets([], PSz,
 		     PKB#pkt_buf { send_nagle = {nagle, Bin}}, Acc).


send_window(#pkt_buf { seq_no = SeqNo,
		       ack_no = AckNo }) ->
    bit16(SeqNo - AckNo).

mk_pkt(Bin, SeqNo, AckNo) ->
    #pkt_wrap {
	%% Will fill in the remaining entries later
	packet = #packet {
	  ty = st_data,
	  conn_id = none,
	  win_sz = none,
	  seq_no = SeqNo,
	  ack_no = AckNo,
	  extension = [],
	  payload = Bin
	 },
	transmissions = 0,
	need_resend = false }.








