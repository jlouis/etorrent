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
		   retransmission_queue = [] :: [#packet_wrap{}],
		   ack_no   :: 0..16#FFFF % Next expected packet
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

handle_packet(_CurrentTimeMs,
	      #packet { seq_no = SeqNo,
			ack_no = AckNo,
			payload = Payload,
			ty = _Type } = _Packet,
	      _ProcInfo,
	   PacketBuffer) ->
    N_PB = case update_recv_buffer(SeqNo, Payload, PacketBuffer) of
	       duplicate -> PacketBuffer; % Perhaps do something else here
	       #pkt_buf{} = PB -> PB
	   end,
    N_PB1 = update_send_buffer(AckNo, N_PB),
    {ok, N_PB1}.

update_send_buffer(AckNo, #pkt_buf { retransmission_queue = RQ } = PB) ->
    N_RQ = lists:filter(
	     fun(#packet_wrap {
		    packet = Pkt }) ->
		     Pkt#packet.seq_no >= AckNo % @todo Wrapping!
	     end,
	     RQ),
    PB#pkt_buf { retransmission_queue = N_RQ }.

update_recv_buffer(_SeqNo, <<>>, PB) -> PB;
update_recv_buffer(SeqNo,
		     Payload,
		     #pkt_buf { ack_no = AckNo } = PB)
  when SeqNo == AckNo+1 ->
    %% This is the next expected packet, yay!
    N_PB = enqueue_payload(Payload, PB),
    satisfy_from_reorder_buffer(N_PB#pkt_buf { ack_no = SeqNo });
update_recv_buffer(SeqNo, Payload, PB) ->
    reorder_buffer_in(SeqNo, Payload, PB).


satisfy_from_reorder_buffer(#pkt_buf { reorder_buf = [] } = PB) ->
    PB;
satisfy_from_reorder_buffer(#pkt_buf { ack_no = AckNo,
				       reorder_buf = [{SeqNo, PL} | R]} = PB)
  when SeqNo == AckNo+1 -> % @todo Wrapping!
    N_PB = enqueue_payload(PL, PB),
    satisfy_from_reorder_buffer(N_PB#pkt_buf { ack_no = SeqNo, reorder_buf = R});
satisfy_from_reorder_buffer(#pkt_buf { ack_no = AckNo,
				       reorder_buf = [{SeqNo, _PL} | _R]} = PB)
  when SeqNo =/= AckNo+1 -> % @todo Wrapping!
    PB.


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






