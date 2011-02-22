%% @doc Low level packet buffer management.
-module(utp_pkt).

-export([
	 mk/0
	 ]).

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


-spec mk() -> t().
mk() ->
    #pkt_info { outbuf_mask = 16#f,
		inbuf_mask  = 16#f,
		outbuf_elements = [], % These two should probably be queues
		inbuf_elements = []
	      }.


