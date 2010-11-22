%%%-------------------------------------------------------------------
%%% File    : etorrent_udp_tracker.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% Description : A FSM representing a UDP tracker state
%%%
%%% Created : 18 Nov 2010 by Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_udp_tracker).

-include("types.hrl").
-include("log.hrl").
-behaviour(gen_fsm).

%% API
-export([start_link/1, announce/2, announce/3]).

%% Internally used calls
-export([msg/2]).

%% gen_fsm callbacks
-export([init/1, idle/2, idle/3, request_conn/2, request_conn/3, has_conn/2, has_conn/3,
	 handle_event/3, handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

-record(state, { conn_id = none,
		 response = [],
	         announce_stack = [] }).

%%====================================================================
-spec start_link({ip(), port()}) -> {ok, pid()}.
start_link(Tracker) ->
    gen_fsm:start_link(?MODULE, [Tracker], []).


announce(Pid, Proplist) ->
    announce(Pid, Proplist, timer:seconds(60)).

%% TODO: consider changing this to the gproc call rather than Pid
announce(Pid, Proplist, Timeout) ->
    %% TODO: This should probably be a gen_fsm:sync_event with a timeout and a
    %% async reply. That way, the interface to the system is much simpler. We can
    %% capture the timeout explicitly and handle it by converting it to a value.

    %% TODO: Consider hauling the TRef with us as well so we can cancel the timer
    TRef = erlang:send_after(Timeout, self(), announce_timeout),
    gen_fsm:send_event(Pid, {announce, self(), Proplist, TRef}),
    {ok, TRef}.

%%====================================================================
%% Retrieve a message from the socket.
msg(Pid, M) ->
    gen_fsm:send_event(Pid, {msg, M}).

init([Tracker]) ->
    gproc:add_local_name({udp_tracker, Tracker}),
    {ok, idle, #state{}, timer:seconds(3600)}.

idle({msg, {_TID, {conn_response, _ConnID}}}, S) ->
    {next_state, idle, S, timer:seconds(3600)};
idle({msg, {TID, {announce_response, Peers, Status}}}, #state { response = R} = S) ->
    announce_reply(Peers, Status, proplists:lookup(TID, R)),
    PL = proplists:delete(TID, R),
    {next_state, idle, S#state { response = PL }, timer:seconds(3600)};
%% The idle state is when we have no outstanding requests running with the server
idle({announce, Requestor, PL, R}, #state { announce_stack = Q } = S) ->
    Tid = request_connid(0),
    {next_state, request_conn, S#state { announce_stack = [{announce, Requestor, PL, R} | Q],
				         conn_id = {req, Tid} }};
idle(Event, S) ->
    ?INFO([unknown_msg, idle, Event, ?MODULE]),
    {next_state, idle, S, timer:seconds(3600)}.

%% The request_conn state is when we have requested a connection ID from the server
request_conn({msg, {TID, {conn_response, ConnID}}}, S) ->
    etorrent_udp_tracker_mgr:unreg_tr_id(TID),
    erlang:send_after(timer:seconds(60), self(), connid_expired),
    ARes = announce_requests(ConnID, S#state.announce_stack),
    {next_state, has_conn, #state { conn_id = ConnID,
				    announce_stack = [],
				    response = S#state.response ++ ARes }};
request_conn({msg, {TID, {announce_response, Peers, Status}}}, #state { response = R} = S) ->
    announce_reply(Peers, Status, proplists:lookup(TID, R)),
    PL = proplists:delete(TID, R),
    {next_state, request_conn, S#state { response = PL }};
request_conn({announce, Requestor, PL, R}, #state { announce_stack = Q } = S) ->
    {next_state, request_conn, S#state { announce_stack = [{announce, Requestor, PL, R} | Q]}};
request_conn(Event, S) ->
    ?INFO([unknown_msg, request_conn, Event, ?MODULE]),
    {next_state, request_conn, S}.

%% The has_conn is when we currently have a live conn ID from the server
has_conn({announce, _, _, _} = M, #state { response = Resp } = S) ->
    Ares = announce_requests(S#state.conn_id, [M]),
    {next_state, has_conn, S#state { response = Ares ++ Resp }};
has_conn({msg, {TID, {announce_response, Peers, Status}}}, #state { response = R} = S) ->
    announce_reply(Peers, Status, proplists:lookup(TID, R)),
    PL = proplists:delete(TID, R),
    {next_state, has_conn, S#state { response = PL }};
has_conn(Event, S) ->
    ?INFO([unknown_msg, has_conn, Event, ?MODULE]),
    {next_state, has_conn, S}.

idle(_Event, _F, S) ->
    {reply, ok, idle, S}.

request_conn(_E, _F, S) ->
    {reply, ok, request_conn, S}.

has_conn(_E, _F, S) ->
    {reply, ok, has_conn, S}.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

handle_info(timeout, idle, _S) ->
    {stop, normal, idle};
handle_info(connid_expired, has_conn, S) ->
    {next_state, idle, S#state { conn_id = none }};
handle_info(connid_expired, SN, S) ->
    {stop, {state_inconsistent, {connid_expired, SN, S}}, idle};
handle_info({announce_timeout, N, Tid}, has_conn,
	    #state { response = R, conn_id = ConnId} = S) ->
    etorrent_udp_tracker_mgr:unreg_tr_id(Tid),
    case proplists:lookup(Tid, R) of
	none ->
	    %% Stray
	    {next_state, has_conn, S};
	{announce, _, _, _} = AnnReq ->
	    NPL = proplists:delete(Tid, R),
	    NewReq = announce_requests(ConnId, [AnnReq], N),
	    %% TODO: Consider messaging back the fail here
	    {next_state, has_conn, S#state { response = NewReq ++ NPL }}
    end;
handle_info({announce_timeout, _N, Tid}, SN, #state { response = R,
						      announce_stack = Stack } = S) ->
    etorrent_udp_tracker_mgr:unreg_tr_id(Tid),
    case proplists:lookup(Tid, R) of
	none ->
	    {next_state, has_conn, S};
	{announce, _, _, _} = AnnReq ->
	    NPL = proplists:delete(Tid, R),
	    %% If idle, grab hold of a conn_id!
	    NewTid = case SN of
			 request_conn -> S#state.conn_id;
			 idle -> Tid = request_connid(0),
				 {req, Tid}
		     end,
	    {next_state, request_conn, S#state { response = NPL,
						 conn_id = NewTid,
						 announce_stack = [AnnReq | Stack] }}
    end;
handle_info({transaction_timeout, N, Tid}, request_conn,
	    #state { conn_id = {req, Tid} } = S) ->
    etorrent_udp_tracker_mgr:unreg_tr_id(Tid),
    NewTid = case N of
		 8 -> request_connid(8);
		 K when is_integer(K) -> request_connid(K+1)
	     end,
    {next_state, request_conn, S#state { conn_id = {req, NewTid} }};
handle_info({transaction_timeout, _, _}, SN, S) ->
    %% These are stray
    {next_state, SN, S};
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%--------------------------------------------------------------------
request_connid(N) ->
    Tid = etorrent_udp_tracker_proto:new_tid(),
    etorrent_udp_tracker_mgr:reg_tr_id(Tid),
    erlang:send_after(expire_time(N), self(), {transaction_timeout, N, Tid}),
    Msg = {conn_request, Tid},
    etorrent_udp_tracker_mgr:msg(Msg),
    Tid.

expire_time(N) ->
    timer:seconds(
      15 * trunc(math:pow(2,N))).

announce_reply(_Peers, _Status, none) -> ignore;
announce_reply(Peers, Status, {announce, Requestor, _PL, Ref}) ->
    Requestor ! {announce, Peers, Status, Ref}.

announce_requests(ConnID, ReqL) ->
    announce_requests(ConnID, ReqL, 0).

announce_requests(ConnID, ReqL, N) ->
    [begin
	 Tid = announce_req(N, ConnID, PL),
	 {Tid, AnnReq}
     end || {announce, _Req, PL, _Ref} = AnnReq <- ReqL].

announce_req(N, ConnID, PropL) ->
    [IH, PeerId, Down, Left, Up, Event, IPAddr, Key, Port] =
	[proplists:get_value(K, PropL) || K <- [info_hash, peer_id, down, left, up, event,
						ip_addr, key, port]],
    Tid = etorrent_udp_tracker_proto:new_tid(),
    etorrent_udp_tracker_mgr:reg_tr_id(Tid),
    erlang:send_after(expire_time(N), self(), {announce_timeout, N, Tid}),
    Msg = {announce_request, ConnID, Tid, IH, PeerId, {Down, Left, Up}, Event, IPAddr, Key,
	   Port},
    etorrent_udp_tracker_mgr:msg(Msg),
    Tid.

