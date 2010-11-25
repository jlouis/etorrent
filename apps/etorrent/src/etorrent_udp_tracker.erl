-module(etorrent_udp_tracker).
-include("types.hrl").
-include("log.hrl").

-behaviour(gen_server).

%% API
-export([start_link/3, start_link/4]).

%% Internally used calls
-export([msg/2, connid/2, cancel/1, cancel_connid/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, { try_count = -1,
	         tracker,
		 ty,
		 connid = none,
		 reply = none,
		 properties = [],
	         tid = none }).

-define(CONNID_TIMEOUT, timer:seconds(60)).

%%====================================================================
%% API
%%====================================================================

%%====================================================================
start_link(requestor, Tracker, N) ->
    gen_server:start_link(?MODULE, [{connid_gather, Tracker, N}], []).

start_link(announce, From, Tracker, PL) ->
    gen_server:start_link(?MODULE, [{announce, From, Tracker, PL}], []).

connid(Pid, ConnID) ->
    gen_server:cast(Pid, {connid, ConnID}).

cancel(Pid) ->
    gen_server:cast(Pid, cancel).

cancel_connid(Pid, ConnID) ->
    gen_server:cast(Pid, {cancel, ConnID}).

msg(Pid, M) ->
    gen_server:cast(Pid, {msg, M}).

%%====================================================================
init([{announce, From, Tracker, PL}]) ->
    etorrent_udp_tracker_mgr:reg_announce(Tracker, PL),
    {ok, #state { tracker = Tracker, ty = announce, reply = From, properties = PL }};
init([{connid_gather, Tracker, N}]) ->
    etorrent_udp_tracker_mgr:reg_connid_gather(Tracker),
    {ok, #state { tracker = Tracker, ty = connid_gather, try_count = N}, 0}.

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
handle_cast(cancel, S) ->
    {stop, normal, S};
handle_cast({connid, ConnID}, #state { ty = announce,
				       properties = PL,
				       tracker = Tracker } = S) ->
    Tid = announce_request(Tracker, ConnID, PL, 0),
    {noreply, S#state { connid = ConnID, try_count = 0, tid = Tid }};
handle_cast({cancel_connid, ConnID}, #state { connid = ConnID} = S) ->
    {noreply, S#state { connid = none }};
handle_cast({msg, {Tid, {announce_response, Peers, Status}}},
	    #state { reply = R, ty = announce, tid = Tid } = S) ->
    etorrent_udp_tracker_mgr:unreg_tr_id(Tid),
    announce_reply(R, Peers, Status),
    {stop, normal, S};
handle_cast({msg, {Tid, {conn_response, ConnID}}},
	    #state { tracker = Tracker, tid = Tid } = S) ->
    etorrent_udp_tracker_mgr:unreg_tr_id(Tid),
    erlang:send_after(?CONNID_TIMEOUT, etorrent_udp_tracker_mgr, {remove_connid, Tracker, ConnID}),
    etorrent_udp_tracker_mgr:reg_connid(Tracker, ConnID),
    etorrent_udp_tracker_mgr:distribute_connid(Tracker, ConnID),
    {stop, normal, S};
handle_cast(Msg, State) ->
    ?WARN([unknown_msg, Msg]),
    {noreply, State}.

handle_info(timeout, #state { tracker=Tracker,
			      try_count=N,
			      ty = announce,
			      tid = OldTid,
			      connid = ConnID } = S) ->
    case OldTid of
	none -> ignore;
	T when is_binary(T) -> etorrent_udp_tracker_mgr:unreg_tr_id(OldTid)
    end,
    case ConnID of
	none ->
	    etorrent_udp_tracker_mgr:need_requestor(Tracker, N),
	    {noreply, S#state { tid = none, try_count = 0 }};
	K when is_integer(K) ->
	    Tid = announce_request(Tracker, ConnID, S#state.properties, inc(N)),
	    {noreply, S#state { tid = Tid, try_count = inc(N)}}
    end;
handle_info(timeout, #state { tracker=Tracker, try_count=N, ty = connid_gather, tid = OldTid } = S) ->
    case OldTid of
	none -> ignore;
	T when is_binary(T) -> etorrent_udp_tracker_mgr:unreg_tr_id(OldTid)
    end,
    Tid = request_connid(Tracker, inc(N)),
    {noreply, S#state { tid = Tid, try_count = inc(N) }};
handle_info(Info, State) ->
    ?WARN([unknown, Info]),
    {noreply, State}.


terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------

announce_request({IP, Port}, ConnID, PropL, N) ->
    [IH, PeerId, Down, Left, Up, Event, Key, Port] =
	[proplists:get_value(K, PropL)
	 || K <- [info_hash, peer_id, down, left, up, event, key, port]],
    Tid = etorrent_udp_tracker_proto:new_tid(),
    etorrent_udp_tracker_mgr:reg_tr_id(Tid),
    erlang:send_after(expire_time(N), self(), timeout),
    Msg = {announce_request, ConnID, Tid, IH, PeerId, {Down, Left, Up}, Event, Key,
	   Port},
    etorrent_udp_tracker_mgr:msg({IP, Port}, Msg),
    Tid.

request_connid({IP, Port}, N) ->
    Tid = etorrent_udp_tracker_proto:new_tid(),
    etorrent_udp_tracker_mgr:reg_tr_id(Tid),
    erlang:send_after(expire_time(N), self(), timeout),
    Msg = {conn_request, Tid},
    etorrent_udp_tracker_mgr:msg({IP, Port}, Msg),
    Tid.

expire_time(N) ->
    timer:seconds(
      15 * trunc(math:pow(2,N))).

announce_reply(From, Peers, Status) ->
    gen_server:reply(From, {announce, Peers, Status}).

inc(8) -> 8;
inc(N) when is_integer(N), N < 8 ->
    N+1.
