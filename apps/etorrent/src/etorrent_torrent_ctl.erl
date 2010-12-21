%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Torrent Control process
%% <p>This process controls a (single) Torrent Download. It is the
%% "first" process started and it checks the torrent for
%% correctness. When it has checked the torrent, it will start up the
%% rest of the needed processes, attach them to the supervisor and
%% then lay dormant for most of the time, until the torrent needs to
%% be stopped again.</p>
%% <p><b>Note:</b> This module is pretty old,
%% and is a prime candidate for some rewriting.</p>
%% @end
-module(etorrent_torrent_ctl).

-behaviour(gen_fsm).

-include("log.hrl").

-ignore_xref([{'start_link', 3}, {start, 1}, {initializing, 2},
	      {started, 2}, {stopped, 2}, {stop, 1}]).
%% API
-export([start_link/3, start/1, stop/1,
         tracker_error_report/2, completed/1,
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

%% @doc Start the server process
-spec start_link(integer(), string(), binary()) ->
        {ok, pid()} | ignore | {error, term()}.
start_link(Id, Path, PeerId) ->
    gen_fsm:start_link(?MODULE, [self(), Id, Path, PeerId], []).

%% @doc Request that the given torrent is stopped
%% @end
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_fsm:send_event(Pid, stop).

%% @doc Request that the given torrent is started
%% @end
-spec start(pid()) -> ok.
start(Pid) ->
    gen_fsm:send_event(Pid, start).

%% @doc Request that the given torrent is checked (eventually again)
%% @end
-spec check_torrent(pid()) -> ok.
check_torrent(Pid) ->
    gen_fsm:send_event(Pid, check_torrent).

%% @doc Report an error from the tracker
%% @end
-spec tracker_error_report(pid(), term()) -> ok.
tracker_error_report(Pid, Report) ->
    gen_fsm:send_event(Pid, {tracker_error_report, Report}).

%% @doc Report a warning from the tracker
%% @end
-spec tracker_warning_report(pid(), term()) -> ok.
tracker_warning_report(Pid, Report) ->
    gen_fsm:send_event(Pid, {tracker_warning_report, Report}).

%% @doc Tell the controlled the torrent is complete
%% @end
-spec completed(pid()) -> ok.
completed(Pid) ->
    gen_fsm:send_event(Pid, completed).

%% ====================================================================

%% @private
init([Parent, Id, Path, PeerId]) ->
    etorrent_table:new_torrent(Path, Parent, Id),
    etorrent_chunk_mgr:new(Id),
    gproc:add_local_name({torrent, Id, control}),
    {ok, initializing, #state{id = Id,
                              path = Path,
                              peer_id = PeerId,
                              parent_pid = Parent}, 0}. % Force timeout instantly.

%% @private
%% @todo Split and simplify this monster function
initializing(timeout, S) ->
    case etorrent_table:acquire_check_token(S#state.id) of
        false ->
            {next_state, initializing, S, ?CHECK_WAIT_TIME};
        true ->
            %% @todo: Try to coalesce some of these operations together.

            %% Read the torrent, check its contents for what we are missing
            etorrent_event:checking_torrent(S#state.id),
            {ok, Torrent, InfoHash, NumberOfPieces} =
                etorrent_fs_checker:read_and_check_torrent(S#state.id,
							   S#state.path),
            etorrent_piece_mgr:add_monitor(self(), S#state.id),
            %% Update the tracking map. This torrent has been started, and we
            %%  know its infohash
            etorrent_table:statechange_torrent(S#state.id, {infohash, InfoHash}),
            etorrent_table:statechange_torrent(S#state.id, started),

	    {AU, AD} =
		case etorrent_fast_resume:query_state(S#state.id) of
		    unknown -> {0,0};
		    {value, PL} ->
			{proplists:get_value(uploaded, PL),
			 proplists:get_value(downloaded, PL)}
		end,
            %% Add a torrent entry for this torrent.
            ok = etorrent_torrent:new(
                   S#state.id,
                   {{uploaded, 0},
                    {downloaded, 0},
		    {all_time_uploaded, AU},
		    {all_time_downloaded, AD},
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
            etorrent_event:started_torrent(S#state.id),
            garbage_collect(),
            {next_state, started,
             S#state{tracker_pid = TrackerPid}}
    end.

%% @private
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
    etorrent_event:completed_torrent(Id),
    etorrent_tracker_communication:completed(TrackerPid),
    {next_state, started, S};
%% @todo kill this
started({tracker_error_report, Reason}, S) ->
    io:format("Got tracker error: ~s~n", [Reason]),
    {next_state, started, S};
started({tracker_warning_report, Reason}, S) ->
    io:format("Got tracker warning report: ~s~n", [Reason]),
    {next_state, started, S}.

%% @private
stopped(start, S) ->
    {stop, argh, S}.

%% @private
handle_event(Msg, SN, S) ->
    io:format("Problem: ~p~n", [Msg]),
    {next_state, SN, S}.

%% @private
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%% @private
handle_info(Info, StateName, State) ->
    ?WARN([unknown_info, Info, StateName]),
    {next_state, StateName, State}.

%% @private
terminate(_Reason, _StateName, _S) ->
    ok.

%% @private
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%% --------------------------------------------------------------------

%% @todo Does this function belong here?
calculate_amount_left(Id) when is_integer(Id) ->
    Pieces = etorrent_piece_mgr:select(Id),
    lists:sum([etorrent_piece_mgr:size_piece(P) || P <- Pieces]).

