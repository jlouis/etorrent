%%% A manager for UDP communication with trackers
-module(etorrent_udp_tracker_mgr).

-behaviour(gen_server).
-include("log.hrl").

%% API
-export([start_link/0, lookup_transaction/1, lookup/1, msg/1, reg_tr_id/1,
	 unreg_tr_id/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, { socket }).

-define(SERVER, ?MODULE).
-define(TAB, etorrent_udp_transact).
-define(DEFAULT_TIMEOUT, timer:seconds(60)).

%%====================================================================
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

lookup_transaction(Tid) ->
    case ets:lookup(?TAB, Tid) of
	[] -> none;
	[{_, Pid}] -> {ok, Pid}
    end.

msg(Msg) ->
    gen_server:cast(?SERVER, {msg, Msg}).

reg_tr_id(Tid) ->
    ets:insert_new(?TAB, {Tid, self()}).

unreg_tr_id(Tid) ->
    true = ets:delete(?TAB, Tid),
    ok.

lookup(Tracker) ->
    case gproc:lookup_pids({udp_tracker, Tracker}) of
	[] ->
	    new_tracker(Tracker),
	    lookup(Tracker);
	[Pid] ->
	    Pid
    end.

%%====================================================================
init([]) ->
    ets:new(?TAB, [named_table, public, {keypos, 1}]),
    {ok, Port} = application:get_env(etorrent, udp_port),
    {ok, Socket} = gen_udp:open(Port, [binary, {active, true}, inet, inet6]),
    {ok, #state{ socket = Socket }}.

handle_call({new_tracker, {IP, Port}}, _From, S) ->
    %% Guard that multiple incoming messages request the same UDP tracker
    case gproc:lookup_pids({udp_tracker, {IP, Port}}) of
	[_] -> {reply, ok, S}; % It has already been created
	[]  ->
	    {ok, Pid} = etorrent_udp_pool_sup:add_udp_tracker({IP, Port}),
	    erlang:monitor(process, Pid),
	    gproc:await({udp_tracker, {IP, Port}}),
	    {reply, ok, S}
    end;
handle_call(Request, _From, State) ->
    ?WARN([unknown_call, Request]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast({msg, M}, S) ->
    Encoded = etorrent_udp_tracker_proto:encode(M),
    gen_udp:send(S#state.socket, Encoded),
    {noreply, S};
handle_cast(Msg, State) ->
    ?WARN([unknown_msg, Msg]),
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, S) ->
    ets:match_delete(?TAB, {'_', Pid}),
    {noreply, S};
handle_info({packet, Packet}, S) ->
    %% If we get a packet in, send it on to the protocol decoder.
    etorrent_udp_tracker_proto:decode_dispatch(Packet),
    {noreply, S};
handle_info(Info, State) ->
    ?WARN([unknown_info, Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
new_tracker(Tracker) ->
    %% This call synchronizes udp tracker process creation, so multiple
    %% simultaneous executions does not matter.
    gen_server:call(?SERVER, {new_tracker, Tracker}).

