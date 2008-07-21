%%%-------------------------------------------------------------------
%%% File    : torrent.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus.local.domain>
%%% License : See COPYING
%%% Description : Representation of a torrent for downloading
%%%
%%% Created :  9 Jul 2007 by Jesper Louis Andersen
%%%   <jlouis@succubus.local.domain>
%%%-------------------------------------------------------------------
-module(etorrent_t_control).

-behaviour(gen_fsm).

-include("etorrent_piece.hrl").

%% API
-export([start_link/3, token/1, start/1, stop/1,
	torrent_checked/2, tracker_error_report/2, seed/1,
	tracker_warning_report/2]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, initializing/2, started/2,
	 stopped/2, handle_sync_event/4, handle_info/3, terminate/3,
	 code_change/4]).

-record(state, {id = none,

		path = none,
		peer_id = none,

		parent_pid = none,
		tracker_pid = none,
		file_system_pid = none,
		peer_group_pid = none,

		disk_state = none,
		available_peers = []}).

-define(CHECK_WAIT_TIME, 3000).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> ok,Pid} | ignore | {error,Error}
%% Description:Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this function
%% does not return until Module:init/1 has returned.
%%--------------------------------------------------------------------
start_link(Id, Path, PeerId) ->
    gen_fsm:start_link(?MODULE, [self(), Id, Path, PeerId], []).

token(Pid) ->
    gen_fsm:send_event(Pid, token).

stop(Pid) ->
    gen_fsm:send_event(Pid, stop).

start(Pid) ->
    gen_fsm:send_event(Pid, start).

torrent_checked(Pid, DiskState) ->
    gen_fsm:send_event(Pid, {torrent_checked, DiskState}).

tracker_error_report(Pid, Report) ->
    gen_fsm:send_event(Pid, {tracker_error_report, Report}).

tracker_warning_report(Pid, Report) ->
    gen_fsm:send_event(Pid, {tracker_warning_report, Report}).

seed(Pid) ->
    gen_fsm:send_event(Pid, seed).

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
init([Parent, Id, Path, PeerId]) ->
    process_flag(trap_exit, true),
    etorrent_tracking_map:new(Path, Parent, Id),
    {ok, initializing, #state{id = Id,
			      path = Path,
			      peer_id = PeerId,
			      parent_pid = Parent}, 0}. % Force timeout instantly.

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
initializing(timeout, S) ->
    case etorrent_tracking_map:is_ready_for_checking(S#state.id) of
	false ->
	    {next_state, initializing, S, ?CHECK_WAIT_TIME};
	true ->
	    %% TODO: Try to coalesce some of these operations together.

	    %% Read the torrent, check its contents for what we are missing
	    etorrent_event_mgr:checking_torrent(S#state.id),
	    {ok, Torrent, FSPid, InfoHash, NumberOfPieces} =
		etorrent_fs_checker:read_and_check_torrent(
		  S#state.id,
		  S#state.parent_pid,
		  S#state.path),
	    %% Update the tracking map. This torrent has been started, and we
	    %%  know its infohash
	    etorrent_tracking_map:statechange(S#state.id, {infohash, InfoHash}),
	    etorrent_tracking_map:statechange(S#state.id, started),

	    %% Add a torrent entry for this torrent.
	    ok = etorrent_torrent:new(
		   S#state.id,
		   {{uploaded, 0},
		    {downloaded, 0},
		    {left, calculate_amount_left(S#state.id)},
		    {total, etorrent_metainfo:get_length(Torrent)}},
		   NumberOfPieces),

	    %% And a process for controlling the peers for this torrent.
	    {ok, PeerGroupPid} =
		etorrent_t_sup:add_peer_group(
		  S#state.parent_pid,
		  S#state.peer_id,
		  InfoHash,
		  S#state.id),

	    %% Start the tracker
	    {ok, TrackerPid} =
		etorrent_t_sup:add_tracker(
		  S#state.parent_pid,
		  PeerGroupPid,
		  etorrent_metainfo:get_url(Torrent),
		  etorrent_metainfo:get_infohash(Torrent),
		  S#state.peer_id,
		  S#state.id),

	    %% Since the process will now go to a hibernation state, GC it
	    etorrent_event_mgr:started_torrent(S#state.id),
	    garbage_collect(),
	    {next_state, started,
	     S#state{file_system_pid = FSPid,
		     tracker_pid = TrackerPid,
		     peer_group_pid = PeerGroupPid}}

    end.

started(stop, S) ->
    {stop, argh, S};
started({tracker_error_report, Reason}, S) ->
    io:format("Got tracker error: ~s~n", [Reason]),
    {next_state, started, S}.

stopped(start, S) ->
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
handle_event(Msg, SN, S) ->
    io:format("Problem: ~p~n", [Msg]),
    {next_state, SN, S}.

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
handle_info(Info, StateName, State) ->
    error_logger:info_report([unknown_info, Info, StateName]),
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, StateName, State) -> void()
%% Description:This function is called by a gen_fsm when it is about
%% to terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _StateName, S) ->
    ok = etorrent_piece_mgr:delete(S#state.id),
    etorrent_torrent:delete(S#state.id),
    ok = etorrent_path_map:delete(S#state.id),
    etorrent_tracking_map:delete(S#state.id),
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
calculate_amount_left(Id) when is_integer(Id) ->
    Pieces = etorrent_piece_mgr:select(Id),
    lists:sum([size_piece(P) || P <- Pieces]).

size_piece(#piece{state = fetched}) -> 0;
size_piece(#piece{state = not_fetched, files = Files}) ->
    lists:sum([Sz || {_F, _O, Sz} <- Files]).



