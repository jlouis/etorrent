%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc A gen_server for UDP tracker decoding/encoding and dispatch.
%% <p>This gen_server can decode tracker messages when those messages
%% are in BEP-15/UDP form. It also has the relevant code for encoding
%% messages for trackers.</p>
%% <p>Note that message decoding includes message dispatch on
%% succesful decodes. In other words, if we decode successfully, we
%% look up the recepient to Transaction ID and forward the message to
%% the recepient.</p>
%% @end
-module(etorrent_udp_tracker_proto).

-include("log.hrl").

-behaviour(gen_server).

%% API
-export([start_link/0, encode/1, decode_dispatch/1, new_tid/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {}).

-define(CONNECT, 0).
-define(ANNOUNCE, 1).
-define(SCRAPE, 2).
-define(ERROR, 3).

-type ipaddr() :: etorrent_types:ipaddr().
-type portnum() :: etorrent_types:portnum().
-type action() :: connect | announce | scrape | error.
-type event() :: none | completed | started | stopped.
-type announce_opt() :: {interval | leechers | seeders, pos_integer()}.
-type scrape_opt() :: {seeders | leechers | completed, pos_integer()}.
-type t_udp_packet() ::
	  {conn_request, action(), pos_integer()}
	| {conn_response, action(), pos_integer(), pos_integer()}
	| {announce_request, pos_integer(), binary(), binary(),
	                     binary(),
	                     {pos_integer(), pos_integer(), pos_integer()},
	                     event(), ipaddr(), pos_integer(), pos_integer()}
	| {announce_response, pos_integer(), [{ipaddr(), portnum()}],
	                                     [announce_opt()]}
	| {scrape_request, pos_integer(), binary(), [binary()]}
	| {scrape_response, pos_integer(), [scrape_opt()]}
	| {error_response, pos_integer(), string()}.

-export_type([t_udp_packet/0]).
-define(SERVER, ?MODULE).

%%====================================================================

%% @doc Start the decoder process
%% @end
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Generate a new unique transaction id
%% @end
new_tid() ->
    crypto:rand_bytes(4).

%% Only allows encoding of the packet types we send to the server
%% @doc Encode a packet in term format to wire format
%%   <p>Note we do not handle all formats, but only those we have been
%% needing up until now</p>
%% @end
encode(P) ->
    case P of
	{conn_request, Tid} ->
	    <<4497486125440:64/big, ?CONNECT:32/big, Tid/binary>>;
	{announce_request, ConnID, Tid, InfoHash, PeerId,
	   {Down, Left, Up}, Event, Key, Port} ->
	    true = is_binary(PeerId),
	    true = is_binary(InfoHash),
	    20 = byte_size(InfoHash),
	    20 = byte_size(PeerId),
	    EventN = encode_event(Event),
	    <<ConnID:64/big, ?ANNOUNCE:32/big, Tid/binary,
	      InfoHash/binary, PeerId/binary,
	      Down:64/big, Left:64/big, Up:64/big,
	      EventN:32/big,
	      0:32/big,
	      Key:32/big,
	      (-1):32/big,
	      Port:16/big>>
    end.

%% @doc Decode packet and dispatch it.
%%   <p>Dispatch will try to look up a receiver of the message by its
%%   transaction id. If this succeeds the message is
%%   forwarded. Otherwise it is silently discarded</p>
%% @end
decode_dispatch(Packet) ->
    %% If the protocol decoder is down, we regard it as if the UDP packet
    %% has been lost in transit. This ought to work.
    gen_server:cast(?SERVER, {decode, Packet}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init([]) ->
    gproc:add_local_name(udp_tracker_proto_decoder),
    {ok, #state{}}.

%% @private
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%% @private
handle_cast({decode, Packet}, S) ->
    dispatch(decode(Packet)),
    {noreply, S};
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------

decode(Packet) ->
    <<Ty:32/big, TID:4/binary, Rest/binary>> = Packet,
    Action = decode_action(Ty),
    case Action of
	    connect ->
		<<ConnectionID:64/big>> = Rest,
		{TID, {conn_response, ConnectionID}};
	    announce ->
		<<Interval:32/big,
		  Leechers:32/big,
		  Seeders:32/big,
		  IPs/binary>> = Rest,
		{TID, {announce_response, etorrent_utils:decode_ips(IPs),
		       [{interval, Interval},
			{leechers, Leechers},
			{seeders, Seeders}]}};
	    scrape ->
		{TID, {scrape_response, decode_scrape(Rest)}};
	    error ->
		{TID, {error_response, TID, binary_to_list(Rest)}}
	end.

dispatch({Tid, Msg}) ->
    case etorrent_udp_tracker_mgr:lookup_transaction(Tid) of
	{ok, Pid} ->
	    etorrent_udp_tracker:msg(Pid, {Tid, Msg});
	none ->
	    ?INFO({ignoring_udp_message, Msg}),
	    ignore %% Too old a message to care about it
    end.

encode_event(Event) ->
    case Event of
	none -> 0;
	completed -> 1;
	started -> 2;
	stopped -> 3
    end.

decode_action(I) ->
    case I of
	?CONNECT -> connect;
	?ANNOUNCE -> announce;
	?SCRAPE -> scrape;
	?ERROR -> error
    end.

decode_scrape( <<>>) -> [];
decode_scrape(<<Seeders:32/big, Completed:32/big, Leechers:32/big, SCLL/binary>>) ->
    [[{seeders, Seeders},
      {completed, Completed},
      {leechers, Leechers}] | decode_scrape(SCLL)].
