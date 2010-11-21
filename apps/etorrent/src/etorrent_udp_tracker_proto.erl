%%%-------------------------------------------------------------------
%%% File    : udp_tracker_proto.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% Description : An UDP protocol decoder process
%%%
%%% Created : 18 Nov 2010 by Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
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

-type action() :: connect | announce | scrape | error.
-type event() :: none | completed | started | stopped.
-type ip() :: {byte(), byte(), byte(), byte()}.
-type announce_opt() :: {interval | leechers | seeders, pos_integer()}.
-type scrape_opt() :: {seeders | leechers | completed, pos_integer()}.
-type t_udp_packet() ::
	  {conn_request, action(), pos_integer()}
	| {conn_response, action(), pos_integer(), pos_integer()}
	| {announce_request, pos_integer(), pos_integer(), binary(),
	                     binary(),
	                     {pos_integer(), pos_integer(), pos_integer()},
	                     event(), ip(), pos_integer(), pos_integer()}
	| {announce_response, pos_integer(), [{ip(), 0..65535}], [announce_opt()]}
	| {scrape_request, pos_integer(), binary(), [binary()]}
	| {scrape_response, pos_integer(), [scrape_opt()]}
	| {error_response, pos_integer(), string()}.

-export_type([t_udp_packet/0]).
-define(SERVER, ?MODULE).

%%====================================================================
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

new_tid() ->
    crypto:rand_bytes(4).

%% Only allows encoding of the packet types we send to the server
-spec encode(t_udp_packet()) -> binary().
encode(P) ->
    case P of
	{conn_request, Tid} ->
	    <<4497486125440:64/big, ?CONNECT:32/big, Tid:32/big>>;
	{announce_request, ConnID, Tid, InfoHash, PeerId,
	   {Down, Left, Up}, Event, IPAddr, Key, Port} ->
	    true = is_binary(PeerId),
	    true = is_binary(InfoHash),
	    20 = byte_size(InfoHash),
	    20 = byte_size(PeerId),
	    EventN = encode_event(Event),
	    IPN = encode_ip(IPAddr),
	    <<ConnID:64/big, ?ANNOUNCE:32/big, Tid:32/big,
	      InfoHash/binary, PeerId/binary,
	      Down:64/big, Left:64/big, Up:64/big,
	      EventN:32/big,
	      IPN/binary,
	      Key:32/big,
	      (-1):32/big,
	      Port:16/big>>;
	{scrape_request, ConnID, Tid, InfoHashes} ->
	    BinHashes = iolist_to_binary(InfoHashes),
	    <<ConnID:64/big,
	      ?SCRAPE:32/big,
	      Tid:32/big,
	      BinHashes/binary>>
    end.

decode_dispatch(Packet) ->
    %% If the protocol decoder is down, we regard it as if the UDP packet
    %% has been lost in transit. This ought to work.
    gen_server:cast(?SERVER, {decode, Packet}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([]) ->
    gproc:add_local_name(udp_tracker_proto_decoder),
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({decode, Packet}, S) ->
    dispatch(decode(Packet)),
    {noreply, S};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
decode(Packet) ->
    <<Ty:32/big, TID:32/big, Rest/binary>> = Packet,
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
		{TID, {announce_response, decode_ips(IPs),
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
	    etorrent_udp_tracker:msg(Pid, Msg);
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

encode_ip({B1, B2, B3, B4}) ->
    <<B1:8, B2:8, B3:8, B4:8>>.

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

decode_ips(<<>>) -> [];
decode_ips(<<B1:8, B2:8, B3:8, B4:8, P:16/big, Rest/binary>>) ->
    [{{B1, B2, B3, B4}, P} | decode_ips(Rest)].
