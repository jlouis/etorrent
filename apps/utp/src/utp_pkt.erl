%% @doc Low level packet buffer management.
-module(utp_pkt).

-include("utp.hrl").

-export([
	 mk/0,
	 packet_size/1,
	 rcv_window/0,
	 mk_random_seq_no/0,
	 send_fin/1,
	 handle_packet/4,
	 buffer_dequeue/1,
	 buffer_putback/2
	 ]).

%% TYPES
%% ----------------------------------------------------------------------
-record(pkt_info, {
	  %% Buffers
	  inbuf_elements :: list(),
	  inbuf_mask     :: integer(),
	  opt_sendbuf    :: integer(),

	  outbuf_elements :: list(),
	  outbuf_mask     :: integer() }).

-type t() :: #pkt_info{}.


-record(packet_wrap, {
	  packet            :: utp_proto:packet(),
	  transmissions = 0 :: integer(),
	  need_resend = false :: integer()
	 }).
-type pkt() :: #packet_wrap{}.

-record(pkt_buf, { recv_buf :: queue(),
		   reorder_buf = [] :: orddict:orddict(),
		   %% When we have a working protocol, this retransmission queue is probably
		   %% Optimization candidate 1 :)
		   retransmission_queue = [] :: [#packet_wrap{}],
		   window_packets :: integer(), % Number of packets currently in the send window
		   ack_no   :: 0..16#FFFF, % Next expected packet
		   seq_no   :: 0..16#FFFF  % Next Sequence number to use when sending packets
			       
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


%% API
%% ----------------------------------------------------------------------

-spec mk() -> t().
mk() ->
    #pkt_info { outbuf_mask = 16#f,
		inbuf_mask  = 16#f,
		outbuf_elements = [], % These two should probably be queues
		inbuf_elements = []
	      }.


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
	      #packet { seq_no = SeqNo,
			ack_no = AckNo,
			payload = Payload,
			ty = _Type } = _Packet,
	      _ProcInfo,
	   PacketBuffer) ->
    SeqAhead = bit16(SeqNo - PacketBuffer#pkt_buf.ack_no),
    if
	SeqAhead >= ?REORDER_BUFFER_SIZE ->
	    %% Packet looong into the future, ignore
	    throw({invalid, is_far_in_future});
	true ->
	    %% Packet ok, feed to rest of system
	    ok
    end,
    N_PB = case update_recv_buffer(SeqAhead, Payload, PacketBuffer) of
	       duplicate -> PacketBuffer; % Perhaps do something else here
	       #pkt_buf{} = PB -> PB
	   end,
    WindowStart = bit16(PacketBuffer#pkt_buf.seq_no - PacketBuffer#pkt_buf.window_packets),
    AckAhead = bit16(AckNo - WindowStart),
    Acks = if
	       AckAhead > PacketBuffer#pkt_buf.window_packets ->
		   0; % The ack number is old, so do essentially nothing in the next part
	       true ->
		   %% -1 here is needed because #pkt_buf.seq_no is one
		   %% ahead It is the next packet to send out, so it
		   %% is one beyond the top end of the window
		   AckAhead -1
	   end,
    N_PB1 = update_send_buffer(Acks, WindowStart, N_PB),
    {ok, N_PB1}.


update_send_buffer(0, _WindowStart, PB) ->
    PB; %% Essentially a duplicate ACK, but we don't do anything about it
update_send_buffer(AckAhead, WindowStart,
		   #pkt_buf { retransmission_queue = RQ } = PB) ->
    {AckedPackets, N_RQ} = lists:partition(
			     fun(#packet_wrap {
				    packet = Pkt }) ->
				     SeqNo = Pkt#packet.seq_no,
				     Dist = bit16(SeqNo - WindowStart),
				     Dist =< AckAhead
			     end,
			     RQ),
    %% @todo This is a placeholder for later when we need LEDBAT congestion control
    _AckedBytes = sum_packets(AckedPackets),
    PB#pkt_buf { retransmission_queue = N_RQ }.

sum_packets(List) ->
    Ps = [byte_size(Pkt#packet.payload) || #packet_wrap { packet = Pkt } <- List],
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






