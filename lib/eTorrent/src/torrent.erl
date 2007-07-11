%%%-------------------------------------------------------------------
%%% File    : torrent.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus.local.domain>
%%% Description : Representation of a torrent for downloading
%%%
%%% Created :  9 Jul 2007 by Jesper Louis Andersen <jlouis@succubus.local.domain>
%%%-------------------------------------------------------------------
-module(torrent).

-behaviour(gen_fsm).

%% API
-export([start_link/0, token/1, start/1, stop/1, load_new_torrent/3]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, initializing/3, waiting_check/2, started/2,
	 stopped/2, handle_sync_event/4, handle_info/3, terminate/3,
	 code_change/4]).

-record(state, {path = none,
		torrent = none,
		peer_id = none}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> ok,Pid} | ignore | {error,Error}
%% Description:Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this function
%% does not return until Module:init/1 has returned.
%%--------------------------------------------------------------------
start_link() ->
    gen_fsm:start_link(?MODULE, [], []).

token(Pid) ->
    gen_fsm:send_event(Pid, token).

stop(Pid) ->
    gen_fsm:send_event(Pid, stop).

start(Pid) ->
    gen_fsm:send_event(Pid, start).

load_new_torrent(Pid, File, PeerId) ->
    gen_fsm:sync_send_event(Pid, {load_new_torrent, File, PeerId}).

%%====================================================================
%% gen_fsm callbacks
%%====================================================================
%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, StateName, State} |
%%                         {ok, StateName, State, Timeout} |
%%                         ignore                              |
%%                         {stop, StopReason}
%% Description:Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/3,4, this function is called by the new process to
%% initialize.
%%--------------------------------------------------------------------
init([]) ->
    {ok, initializing, #state{}}.

%%--------------------------------------------------------------------
%% Function:
%% state_name(Event, State) -> {next_state, NextStateName, NextState}|
%%                             {next_state, NextStateName,
%%                                NextState, Timeout} |
%%                             {stop, Reason, NewState}
%% Description:There should be one instance of this function for each possible
%% state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_event/2, the instance of this function with the same name as
%% the current state name StateName is called to handle the event. It is also
%% called if a timeout occurs.
%%--------------------------------------------------------------------
waiting_check(token, S) ->
    ok = serializer:release_token(),
    {next_state, started, S};
waiting_check(stop, S) ->
    {next_state, stopped, S}.

started(stop, S) ->
    {next_state, stopped, S};
started(token, S) ->
    ok = serializer:release_token(),
    {next_state, started, S}.

stopped(start, S) ->
    {next_state, started, S};
stopped(token, S) ->
    ok = serializer:release_token(),
    {next_state, stopped, S}.


%%--------------------------------------------------------------------
%% Function:
%% state_name(Event, From, State) -> {next_state, NextStateName, NextState} |
%%                                   {next_state, NextStateName,
%%                                     NextState, Timeout} |
%%                                   {reply, Reply, NextStateName, NextState}|
%%                                   {reply, Reply, NextStateName,
%%                                    NextState, Timeout} |
%%                                   {stop, Reason, NewState}|
%%                                   {stop, Reason, Reply, NewState}
%% Description: There should be one instance of this function for each
%% possible state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_event/2,3, the instance of this function with the same
%% name as the current state name StateName is called to handle the event.
%%--------------------------------------------------------------------
% Load a torrent at Path with Torrent
initializing({load_new_torrent, Path, PeerId}, _From, S) ->
    NewState = S#state{path = Path,
		       torrent = none,
		       peer_id = PeerId},
    case serializer:request_token() of
	ok ->
	    ok = serializer:release_token(),
	    {reply, ok, started, NewState};
	wait ->
	    {reply, ok, waiting_check, NewState}
    end.

%%--------------------------------------------------------------------
%% Function:
%% handle_event(Event, StateName, State) -> {next_state, NextStateName,
%%						  NextState} |
%%                                          {next_state, NextStateName,
%%					          NextState, Timeout} |
%%                                          {stop, Reason, NewState}
%% Description: Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%--------------------------------------------------------------------
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% Function:
%% handle_sync_event(Event, From, StateName,
%%                   State) -> {next_state, NextStateName, NextState} |
%%                             {next_state, NextStateName, NextState,
%%                              Timeout} |
%%                             {reply, Reply, NextStateName, NextState}|
%%                             {reply, Reply, NextStateName, NextState,
%%                              Timeout} |
%%                             {stop, Reason, NewState} |
%%                             {stop, Reason, Reply, NewState}
%% Description: Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/2,3, this function is called to handle
%% the event.
%%--------------------------------------------------------------------
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%%--------------------------------------------------------------------
%% Function:
%% handle_info(Info,StateName,State)-> {next_state, NextStateName, NextState}|
%%                                     {next_state, NextStateName, NextState,
%%                                       Timeout} |
%%                                     {stop, Reason, NewState}
%% Description: This function is called by a gen_fsm when it receives any
%% other message than a synchronous or asynchronous event
%% (or a system message).
%%--------------------------------------------------------------------
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, StateName, State) -> void()
%% Description:This function is called by a gen_fsm when it is about
%% to terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _StateName, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Function:
%% code_change(OldVsn, StateName, State, Extra) -> {ok, StateName, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
%% start(TorrentPid) ->
%%     gen_server:cast(TorrentPid, start).

%% stop(TorrentPid) ->
%%     gen_server:cast(TorrentPid, stop).

%% init({F, Torrent, PeerId}) ->
%%     {ok, StatePid} = gen_server:start_link(torrent_state, [], []),
%%     {ok, TrackerDelegatePid} =
%% 	gen_server:start_link(tracker_delegate,
%% 			      {self(), StatePid,
%% 			       metainfo:get_url(Torrent),
%% 			       metainfo:get_infohash(Torrent),
%% 			       PeerId}, []),
%%     io:format("Process for torrent ~s started~n", [F]),
%%     {ok, {F, Torrent, StatePid, TrackerDelegatePid}}.

%% handle_call(_Call, _Who, S) ->
%%     {noreply, S}.

%% terminate_children(_StatePid, _TrackerDelegatePid) ->
%%     ok.

%% terminate(shutdown, {_F, _Torrent, StatePid, TrackerDelegatePid}) ->
%%     terminate_children(StatePid, TrackerDelegatePid),
%%     ok.

%% handle_cast(start, {F, Torrent, StatePid, TrackerDelegatePid}) ->
%%     gen_server:cast(TrackerDelegatePid, start),
%%     {noreply, {F, Torrent, StatePid, TrackerDelegatePid}};
%% handle_cast(stop, {_F, _Torrent, StatePid, TrackerDelegatePid}) ->
%%     gen_server:cast(StatePid, stop),
%%     gen_server:cast(TrackerDelegatePid, stop);


%% %% These are Error cases. We should just try again later (Default request timeout value)
%% handle_cast({tracker_request_failed, Err}, State) ->
%%     error_logger:error_msg("Tracker request failed ~s~n", [Err]),
%%     {noreply, State};
%% handle_cast({tracker_responded_not_bcode, Err}, State) ->
%%     error_logger:error_msg("Tracker did not respond with a bcoded dict: ~s~n", [Err]),
%%     {noreply, State}.
