%%% A manager for UDP communication with trackers
-module(etorrent_udp_tracker_mgr).

-behaviour(gen_server).
-include("log.hrl").

%% API
-export([start_link/0, announce/2, announce/3]).

%% Internal API
-export([msg/2, reg_connid_gather/1, reg_tr_id/1, unreg_tr_id/1,
	 lookup_transaction/1, distribute_connid/2, reg_announce/2,
	 need_requestor/2, reg_connid/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, { socket }). % Might not be needed at all

-define(SERVER, ?MODULE).
-define(TAB, etorrent_udp_transact).
-define(DEFAULT_TIMEOUT, timer:seconds(60)).

%%====================================================================
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

announce(Tr, PL) ->
    announce(Tr, PL, timer:seconds(60)).

announce({IP, Port}, PropList, Timeout) ->
    case catch gen_server:call(?MODULE, {announce, {IP, Port}, PropList}, Timeout) of
	{'EXIT', {timeout, _}} ->
	    gen_server:cast(?MODULE, {announce_cancel, {IP, Port}, PropList}),
	    timeout;
	Response -> {ok, Response}
    end.

distribute_connid(Tracker, ConnID) ->
    gen_server:cast(?MODULE, {distribute_connid, Tracker, ConnID}).

need_requestor(Tracker, N) ->
    gen_server:cast(?MODULE, {need_requestor, Tracker, N}).

lookup_transaction(Tid) ->
    case ets:lookup(?TAB, Tid) of
	[] ->
	    none;
	[{_, Pid}] ->
	    {ok, Pid}
    end.

reg_connid_gather(Tracker) ->
    ets:insert(?TAB, [{{conn_id_req, Tracker}, self()},
		      {self(), {conn_id_req, Tracker}}]).

reg_tr_id(Tid) ->
    true = ets:insert(?TAB, [{Tid, self()}, {self(), Tid}]).

unreg_tr_id(Tid) ->
    [true] = delete_object(?TAB, [{Tid, self()}, {self(), Tid}]).

reg_announce(Tracker, PL) ->
    true = ets:insert(?TAB, [{{announce, Tracker}, self()},
			     {{Tracker, PL}, self()},
			     {self(), {Tracker, PL}}]).

reg_connid(Tracker, ConnID) ->
    ets:insert(?TAB, [{{conn_id, Tracker}, ConnID}]).

msg(Tr, M) ->
    gen_server:cast(?MODULE, {msg, Tr, M}).

%%====================================================================
init([]) ->
    ets:new(?TAB, [named_table, public, {keypos, 1}, bag]),
    {ok, Port} = application:get_env(etorrent, udp_port),
    {ok, Socket} = gen_udp:open(Port, [binary, {active, true}, inet, inet6]),
    {ok, #state{ socket = Socket }}.

handle_call({announce, Tracker, PL}, From, S) ->
    case ets:lookup(?TAB, {conn_id, Tracker}) of
	[] ->
	    spawn_announce(From, Tracker, PL),
	    spawn_requestor(Tracker),
	    {noreply, S};
	[ConnId] ->
	    {ok, Pid} = spawn_announce(From, Tracker, PL),
	    etorrent_udp_tracker:connid(Pid, ConnId),
	    {noreply, S}
    end;
handle_call(Request, _From, State) ->
    ?WARN([unknown_call, Request]),
    Reply = ok,
    {reply, Reply, State}.


handle_cast({need_requestor, Tracker, N}, S) ->
    case ets:lookup(?TAB, {conn_id_req, Tracker}) of
	[] ->
	    spawn_requestor(Tracker, N);
	[_|_] ->
	    ignore
    end,
    {noreply, S};
handle_cast({announce_cancel, Tracker, PL}, S) ->
    case ets:lookup(?TAB, {Tracker, PL}) of
	[] ->
	    %% Already done
	    {noreply, S};
	[{_, Pid}] ->
	    etorrent_udp_tracker:cancel(Pid),
	    {noreply, S}
    end;
handle_cast({distribute_connid, Tracker, ConnID}, S) ->
    Pids = ets:lookup(?TAB, {announce, Tracker}),
    [etorrent_udp_tracker:connid(P, ConnID) || {_, P} <- Pids],
    {noreply, S};
handle_cast({msg, {IP, Port}, M}, S) ->
    Encoded = etorrent_udp_tracker_proto:encode(M),
    ok = gen_udp:send(S#state.socket, IP, Port, Encoded),
    {noreply, S};
handle_cast(Msg, State) ->
    ?WARN([unknown_msg, Msg]),
    {noreply, State}.

handle_info({udp, _, _IP, _Port, Packet}, S) ->
    etorrent_udp_tracker_proto:decode_dispatch(Packet),
    {noreply, S};
handle_info({remove_connid, Tracker, ConnID}, S) ->
    ets:delete_object(?TAB, {{conn_id, Tracker}, ConnID}),
    Pids = ets:lookup(?TAB, {announce, Tracker}),
    [etorrent_udp_tracker:cancel_connid(P, ConnID) || {_, P} <- Pids],
    {noreply, S};
handle_info({'DOWN', _, _, Pid, _}, S) ->
    Objects = ets:lookup(?TAB, Pid),
    R = [case Obj of
	     {Pid, Tid} when is_binary(Tid) ->
		 [true] = delete_object(?TAB, [{Pid, Tid}, {Tid, Pid}]),
		 none;
	     {Pid, {conn_id_req, Tracker}} = Obj ->
		 [true] = delete_object(?TAB, [Obj,
					       {{conn_id_req, Tracker}, Pid}]),
		 {announce, Tracker};
	     {Pid, {Tracker, PL}} = Obj ->
		 [true] = delete_object(?TAB, [Obj,
					       {{Tracker, PL}, Pid},
					       {{announce, Tracker}, Pid}]),
		 {announce, Tracker}
	 end || Obj <- Objects],
    [case ets:lookup(?TAB, {announce, Tr}) of
	 [] ->
	     cancel_conn_id_req(Tr);
	 [_|_] ->
	     ignore
     end || {announce, Tr} <- lists:usort(R)],
    {noreply, S};
handle_info(Info, State) ->
    ?WARN([unknown_info, Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
spawn_requestor(Tr) ->
    spawn_requestor(Tr, 0).

spawn_requestor(Tr, N) ->
    {ok, Pid} = etorrent_udp_pool_sup:start_requestor(Tr, N),
    erlang:monitor(process, Pid),
    {ok, Pid}.

spawn_announce(From, Tr, PL) ->
    {ok, Pid} = etorrent_udp_pool_sup:start_announce(From, Tr, PL),
    erlang:monitor(process, Pid),
    {ok, Pid}.

cancel_conn_id_req(Tr) ->
    case ets:lookup(?TAB, {conn_id_req, Tr}) of
	[] ->
	    ignore;
	[{_, Pid}] ->
	    etorrent_udp_tracker:cancel(Pid)
    end.

delete_object(Tbl, Lst) ->
    Res = [ets:delete_object(Tbl, Item) || Item <- Lst],
    lists:usort(Res).

