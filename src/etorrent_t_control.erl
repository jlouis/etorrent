%%%-------------------------------------------------------------------
%%% File    : etorrent_t_control.erl
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
-include("log.hrl").

%% API
-export([start_link/3, start/1, stop/1,
        torrent_checked/2, tracker_error_report/2, completed/1,
        tracker_warning_report/2,

        check_torrent/1]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, initializing/2, started/2,
         stopped/2, handle_sync_event/4, handle_info/3, terminate/3,
         code_change/4]).

-record(state, {id = none,

                path = none,
                peer_id = none,

                parent_pid = none,
                tracker_pid = none,
                disk_state = none,
                available_peers = []}).

-define(CHECK_WAIT_TIME, 3000).

%% ====================================================================
-spec start_link(integer(), string(), binary()) ->
        {ok, pid()} | ignore | {error, term()}.
start_link(Id, Path, PeerId) ->
    gen_fsm:start_link(?MODULE, [self(), Id, Path, PeerId], []).

% @doc Request that the given torrent is stopped
% @end
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_fsm:send_event(Pid, stop).

% @doc Request that the given torrent is started
% @end
-spec start(pid()) -> ok.
start(Pid) ->
    gen_fsm:send_event(Pid, start).

% @doc Request that the given torrent is checked (eventually again)
% @end
-spec check_torrent(pid()) -> ok.
check_torrent(Pid) ->
    gen_fsm:send_event(Pid, check_torrent).

% @todo Document this function
-spec torrent_checked(pid(), integer()) -> ok.
torrent_checked(Pid, DiskState) ->
    gen_fsm:send_event(Pid, {torrent_checked, DiskState}).

% @doc Report an error from the tracker
% @end
-spec tracker_error_report(pid(), term()) -> ok.
tracker_error_report(Pid, Report) ->
    gen_fsm:send_event(Pid, {tracker_error_report, Report}).

% @doc Report a warning from the tracker
% @end
-spec tracker_warning_report(pid(), term()) -> ok.
tracker_warning_report(Pid, Report) ->
    gen_fsm:send_event(Pid, {tracker_warning_report, Report}).

-spec completed(pid()) -> ok.
completed(Pid) ->
    gen_fsm:send_event(Pid, completed).

%% ====================================================================

init([Parent, Id, Path, PeerId]) ->
    etorrent_tracking_map:new(Path, Parent, Id),
    etorrent_chunk_mgr:new(Id),
    gproc:add_local_name({torrent, Id, control}),
    {ok, initializing, #state{id = Id,
                              path = Path,
                              peer_id = PeerId,
                              parent_pid = Parent}, 0}. % Force timeout instantly.

initializing(timeout, S) ->
    case etorrent_tracking_map:is_ready_for_checking(S#state.id) of
        false ->
            {next_state, initializing, S, ?CHECK_WAIT_TIME};
        true ->
            %% TODO: Try to coalesce some of these operations together.

            %% Read the torrent, check its contents for what we are missing
            etorrent_event_mgr:checking_torrent(S#state.id),
            {ok, Torrent, InfoHash, NumberOfPieces} =
                etorrent_fs_checker:read_and_check_torrent(S#state.id,
							   S#state.path),
            etorrent_piece_mgr:add_monitor(self(), S#state.id),
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

            %% Start the tracker
            {ok, TrackerPid} =
                etorrent_t_sup:add_tracker(
                  S#state.parent_pid,
                  etorrent_metainfo:get_url(Torrent),
                  etorrent_metainfo:get_infohash(Torrent),
                  S#state.peer_id,
                  S#state.id),

            %% Since the process will now go to a hibernation state, GC it
            etorrent_event_mgr:started_torrent(S#state.id),
            garbage_collect(),
            {next_state, started,
             S#state{tracker_pid = TrackerPid}}
    end.

started(stop, S) ->
    {stop, argh, S};
started(check_torrent, S) ->
    case etorrent_fs_checker:check_torrent(S#state.id) of
        [] -> {next_state, started, S};
        Errors ->
            ?INFO([errornous_pieces, {Errors}]),
            {next_state, started, S}
    end;
started(completed, #state { id = Id, tracker_pid = TrackerPid } = S) ->
    etorrent_event_mgr:completed_torrent(Id),
    etorrent_tracker_communication:completed(TrackerPid),
    {next_state, started, S};
started({tracker_error_report, Reason}, S) ->
    io:format("Got tracker error: ~s~n", [Reason]),
    {next_state, started, S}.

stopped(start, S) ->
    {stop, argh, S}.

handle_event(Msg, SN, S) ->
    io:format("Problem: ~p~n", [Msg]),
    {next_state, SN, S}.

handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

handle_info(Info, StateName, State) ->
    ?WARN([unknown_info, Info, StateName]),
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _S) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%% --------------------------------------------------------------------
calculate_amount_left(Id) when is_integer(Id) ->
    Pieces = etorrent_piece_mgr:select(Id),
    lists:sum([size_piece(P) || P <- Pieces]).

size_piece(#piece{state = fetched}) -> 0;
size_piece(#piece{state = not_fetched, files = Files}) ->
    lists:sum([Sz || {_F, _O, Sz} <- Files]).



