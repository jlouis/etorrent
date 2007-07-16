%%%-------------------------------------------------------------------
%%% File    : torrent.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus.local.domain>
%%% Description : Representation of a torrent for downloading
%%%
%%% Created :  9 Jul 2007 by Jesper Louis Andersen <jlouis@succubus.local.domain>
%%%-------------------------------------------------------------------
-module(torrent_control).

-behaviour(gen_fsm).

%% API
-export([start_link/0, token/1, start/1, stop/1, load_new_torrent/3,
	torrent_checked/2, new_peers/2, tracker_error_report/2,
	tracker_warning_report/2]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, initializing/2, waiting_check/2, started/2,
	 stopped/2, handle_sync_event/4, handle_info/3, terminate/3,
	 code_change/4]).

-record(state, {path = none,
		torrent = none,
		peer_id = none,
		work_dir = none,
	        checker_pid = none,
		state_pid = none,
		tracker_pid = none,
		file_system_pid = none,
		disk_state = none,
	        torrent_pid = none}).

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
    gen_fsm:send_event(Pid, {load_new_torrent, File, PeerId}).

torrent_checked(Pid, DiskState) ->
    gen_fsm:send_event(Pid, {torrent_checked, DiskState}).

new_peers(Pid, NewIps) ->
    gen_fsm:send_event(Pid, {new_ips, NewIps}).

tracker_error_report(Pid, Report) ->
    gen_fsm:send_event(Pid, {tracker_error_report, Report}).

tracker_warning_report(Pid, Report) ->
    gen_fsm:send_event(Pid, {tracker_warning_report, Report}).


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
    {ok, WorkDir} = application:get_env(etorrent, dir),
    {ok, initializing, #state{work_dir = WorkDir}}.

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
% Load a torrent at Path with Torrent
initializing({load_new_torrent, Path, PeerId}, S) ->
    {ok, Torrent, Files} =
	check_torrent:load_torrent(S#state.work_dir, Path),
    ok = check_torrent:ensure_file_sizes_correct(Files),
    {ok, FileDict} = check_torrent:build_dictionary_on_files(Torrent, Files),
    {ok, FS, NewState} = add_filesystem(FileDict,
					S#state{path = Path,
						torrent = Torrent,
						peer_id = PeerId}),
    case serializer:request_token() of
	ok ->
	    NS = check_and_start_torrent(FS, FileDict, NewState),
	    {next_state, started, NS};
	wait ->
	    {next_state, waiting_check, NewState#state{disk_state = FileDict,
						      file_system_pid = FS}}
    end.

check_and_start_torrent(FS, FileDict, S) ->
    {ok, DiskState} =
	check_torrent:check_torrent_contents(FS, FileDict),
    ok = serializer:release_token(),
    {ok, Port} = portmanager:fetch_port(),
    {ok, StatePid} = torrent_state:start_link(Port,
					      calculate_amount_left(DiskState)),
    {ok, TrackerPid} =
	tracker_delegate:start_link(self(),
				    StatePid,
				    metainfo:get_url(S#state.torrent),
				    metainfo:get_infohash(S#state.torrent),
				    S#state.peer_id),
    tracker_delegate:start_now(TrackerPid),
    S#state{disk_state = DiskState,
	    file_system_pid = FS,
	    tracker_pid = TrackerPid,
	    state_pid = StatePid}.


waiting_check(token, S) ->
    NS = check_and_start_torrent(S#state.file_system_pid,
				 S#state.disk_state,
				 S),
    {next_state, started, NS};
waiting_check(stop, S) ->
    {next_state, stopped, S}.

started(stop, S) ->
    {stop, argh, S};
started({new_ips, IPList}, S) ->
    io:format("Saw new ips: ~p~n", [IPList]),
    {next_state, started, S};
started({tracker_error_report, Reason}, S) ->
    io:format("Got tracker error: ~s~n", [Reason]),
    {next_state, started, S};
started(token, S) ->
    ok = serializer:release_token(),
    {next_state, started, S}.

stopped(start, S) ->
    {stop, argh, S};
stopped(token, S) ->
    ok = serializer:release_token(),
    {stop, argh, S}.

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
handle_event({'EXIT', _Pid, _Reason}, _SN, S) ->
    {stop, pid_terminated, S};
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
add_filesystem(FileDict, S) ->
    {ok, FS} = file_system:start_link(FileDict),
    {ok, FS, S#state{file_system_pid = FS}}.

calculate_amount_left(DiskState) ->
    dict:fold(fun (_K, {_Hash, Ops, Ok}, Total) ->
		      case Ok of
			  ok ->
			      Total;
			  not_ok ->
			      Total + size_of_ops(Ops)
		      end
	      end,
	      0,
	      DiskState).

size_of_ops(Ops) ->
    lists:foldl(fun ({_Path, _Offset, Size}, Total) ->
			Size + Total end,
		0,
		Ops).


