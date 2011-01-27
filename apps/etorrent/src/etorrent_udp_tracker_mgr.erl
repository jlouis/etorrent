%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Handle the UDP tracker protocol.
%% <p>This module is a central module to UDP tracker requests (BEP-15
%% support). It provides an interface that torrents can use to query
%% the UDP tracker with. The call is currently blocking, so the other
%% process is not going to do anything while waiting for a
%% response. The default timeout-i-give-up-time is 60 seconds.</p>
%% <p>Apart from serving as the main entry point, this module also
%% implements a Manager gen_server which is used to manage the current
%% outstanding requests, their types and which processes are
%% responsible for the different requests. Data is ETS-stored and
%% monitors are used to clean up.</p>
%% <p>The granularity is one process per request-event. The
%% event-processes are defined in the module etorrent_udp_tracker. It
%% is easier to handle timeout and such in a separate process rather
%% than keep centrally track of it.</p>
%% @end
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

-record(state, { socket :: gen_udp:socket() }). % Might not be needed at all

-define(SERVER, ?MODULE).
-define(TAB, etorrent_udp_transact).
-define(DEFAULT_TIMEOUT, timer:seconds(60)).

%%====================================================================

%% @doc Start the Manager process
%% @end
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Announce as announce(Tr, PL, Timeout) with 60 sec timeout.
%% @end
announce(Tr, PL) ->
    announce(Tr, PL, timer:seconds(60)).


%% @doc Announce to the tracker.
%%   <p>PL contains the announce data, Tr is a {IP, Port} tracker
%%   pair, and Timeout is the timeout.</p>
%%   <p>The will block the caller</p>
%% @end
%% @todo Describe the announce data
announce({IP, Port}, PropList, Timeout) ->
    case catch gen_server:call(?MODULE, {announce, {IP, Port}, PropList}, Timeout) of
	{'EXIT', {timeout, _}} ->
	    gen_server:cast(?MODULE, {announce_cancel, {IP, Port}, PropList}),
	    timeout;
	Response -> {ok, Response}
    end.

%% @private
distribute_connid(Tracker, ConnID) ->
    gen_server:cast(?MODULE, {distribute_connid, Tracker, ConnID}).

%% @private
need_requestor(Tracker, N) ->
    gen_server:cast(?MODULE, {need_requestor, Tracker, N}).

%% @private
lookup_transaction(Tid) ->
    case ets:lookup(?TAB, Tid) of
	[] ->
	    none;
	[{_, Pid}] ->
	    {ok, Pid}
    end.

%% @private
reg_connid_gather(Tracker) ->
    ets:insert(?TAB, [{{conn_id_req, Tracker}, self()},
		      {self(), {conn_id_req, Tracker}}]).

%% @private
reg_tr_id(Tid) ->
    true = ets:insert(?TAB, [{Tid, self()}, {self(), Tid}]).

%% @private
unreg_tr_id(Tid) ->
    [true] = delete_object(?TAB, [{Tid, self()}, {self(), Tid}]).

%% @private
reg_announce(Tracker, PL) ->
    true = ets:insert(?TAB, [{{announce, Tracker}, self()},
			     {{Tracker, PL}, self()},
			     {self(), {Tracker, PL}}]).

%% @private
reg_connid(Tracker, ConnID) ->
    ets:insert(?TAB, [{{conn_id, Tracker}, ConnID}]).

%% @private
msg(Tr, M) ->
    gen_server:cast(?MODULE, {msg, Tr, M}).

%%====================================================================

%% @private
init([]) ->
    ets:new(?TAB, [named_table, public, {keypos, 1}, bag]),
    Port = etorrent_config:udp_port(),
    {ok, Socket} = gen_udp:open(Port, [binary, {active, true}, inet, inet6]),
    {ok, #state{ socket = Socket }}.

%% @private
handle_call({announce, Tracker, PL}, From, S) ->
    case ets:lookup(?TAB, {conn_id, Tracker}) of
	[] ->
	    spawn_announce(From, Tracker, PL),
	    spawn_requestor(Tracker),
	    {noreply, S};
	[{_Key, ConnId}] ->
	    {ok, Pid} = spawn_announce(From, Tracker, PL),
	    etorrent_udp_tracker:connid(Pid, ConnId),
	    {noreply, S}
    end;
handle_call(Request, _From, State) ->
    ?WARN([unknown_call, Request]),
    Reply = ok,
    {reply, Reply, State}.

%% @private
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

%% @private
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

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
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

