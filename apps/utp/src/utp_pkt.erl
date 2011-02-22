%% @doc Low level packet buffer management.
-module(utp_pkt).

-include("utp.hrl").

-export([
	 mk/0,
	 packet_size/1,
	 rcv_window/0,
	 mk_random_seq_no/0,
	 send_fin/1
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

%% Track send quota available
-record(send_quota, {
	  send_quota :: integer(),
	  last_send_quota :: integer()
	 }).
-type quota() :: #send_quota{}.

-export_type([t/0,
	      pkt/0,
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











