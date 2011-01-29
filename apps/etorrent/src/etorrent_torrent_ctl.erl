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

-include("types.hrl").
-include("log.hrl").

-ignore_xref([{'start_link', 3}, {start, 1}, {initializing, 2},
	      {started, 2}]).
%% API
-export([start_link/3, completed/1, check_torrent/1]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, initializing/2, started/2,
         handle_sync_event/4, handle_info/3, terminate/3,
         code_change/4]).

-record(state, {id                :: integer() ,
                path              :: string(),
                peer_id           :: binary(),
                parent_pid        :: pid(),
                tracker_pid       :: pid()   }).

-define(CHECK_WAIT_TIME, 3000).

%% ====================================================================

%% @doc Start the server process
-spec start_link(integer(), string(), binary()) ->
        {ok, pid()} | ignore | {error, term()}.
start_link(Id, Path, PeerId) ->
    gen_fsm:start_link(?MODULE, [self(), Id, Path, PeerId], []).

%% @doc Request that the given torrent is checked (eventually again)
%% @end
-spec check_torrent(pid()) -> ok.
check_torrent(Pid) ->
    gen_fsm:send_event(Pid, check_torrent).

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
                read_and_check_torrent(S#state.id,
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
                    {left, calculate_amount_left(S#state.id, NumberOfPieces, Torrent)},
                    {total, etorrent_metainfo:get_length(Torrent)}},
                   NumberOfPieces),

            %% Start the tracker
            {ok, TrackerPid} =
                etorrent_torrent_sup:start_child_tracker(
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
started(check_torrent, S) ->
    case check_torrent_for_bad_pieces(S#state.id) of
        [] -> {next_state, started, S};
        Errors ->
            ?INFO([errornous_pieces, {Errors}]),
            {next_state, started, S}
    end;
started(completed, #state { id = Id, tracker_pid = TrackerPid } = S) ->
    etorrent_event:completed_torrent(Id),
    etorrent_tracker_communication:completed(TrackerPid),
    {next_state, started, S}.

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
calculate_amount_left(Id, NumPieces, Torrent) when is_integer(Id) ->
    Length = etorrent_metainfo:get_length(Torrent),
    PieceL = etorrent_metainfo:get_piece_length(Torrent),
    LastPiece = NumPieces - 1,
    LastPieceSize = Length rem PieceL,
    Downloaded =
	lists:sum([case etorrent_piece_mgr:fetched(Id, Pn) of
		       true when Pn == LastPiece -> LastPieceSize;
		       true                      -> PieceL;
		       false                     -> 0
		   end
		   || Pn <- lists:seq(0, NumPieces - 1)]),
    true = Downloaded =< Length,
    Length - Downloaded.

% @doc Check the contents of torrent Id
% <p>We will check a torrent, Id, and report a list of bad pieces.</p>
% @end
-spec check_torrent_for_bad_pieces(integer()) -> [pos_integer()].
check_torrent_for_bad_pieces(Id) ->
    [PN || PN <- etorrent_piece_mgr:pieces(Id),
	   case etorrent_io:check_piece(Id, PN) of
	       {ok, _} ->
		   false;
	       wrong_hash ->
		   true
	   end].

% @doc Read and check a torrent
% <p>The torrent given by Id, at Path (the .torrent file) will be checked for
%  correctness. We return a tuple
%  with various information about said torrent: The decoded Torrent dictionary,
%  the info hash and the number of pieces in the torrent.</p>
% @end
-spec read_and_check_torrent(integer(), string()) -> {ok, bcode(), binary(), integer()}.
read_and_check_torrent(Id, Path) ->
    {ok, Torrent, Infohash, Hashes} =
        initialize_dictionary(Id, Path),

    L = length(Hashes),

    %% Check the contents of the torrent, updates the state of the piecemap
    FS = gproc:lookup_local_name({torrent, Id, fs}),
    case etorrent_fast_resume:query_state(Id) of
	{value, PL} ->
	    case proplists:get_value(state, PL) of
		seeding -> initialize_pieces_seed(Id, Hashes);
		{bitfield, BF} ->
		    initialize_pieces_from_bitfield(Id, BF, Hashes)
	    end;
        %% XXX: The next one here could initialize with not_fetched all over
        unknown ->
	    %% We currently have to pre-populate the piece data here, which is quite
	    %% bad. In the future:
	    %% @todo remove the prepopulation from the piece_mgr code.
            ok = etorrent_piece_mgr:add_pieces(
                   Id,
                  [{PN, Hash, dummy, not_fetched}
		   || {PN, Hash} <- lists:zip(lists:seq(0, L - 1),
					      Hashes)]),
            ok = initialize_pieces_from_disk(FS, Id, Hashes)
    end,

    {ok, Torrent, Infohash, L}.

%% =======================================================================

initialize_dictionary(Id, Path) ->
    %% Load the torrent
    {ok, Torrent, IH} = load_torrent(Path),
    ok = etorrent_io:allocate(Id),
    Hashes = etorrent_metainfo:get_pieces(Torrent),
    {ok, Torrent, IH, Hashes}.

load_torrent(Path) ->
    Workdir = etorrent_config:work_dir(),
    P = filename:join([Workdir, Path]),
    {ok, Torrent} = etorrent_bcoding:parse_file(P),
    InfoHash = etorrent_metainfo:get_infohash(Torrent),
    {ok, Torrent, InfoHash}.

initialize_pieces_seed(Id, Hashes) ->
    L = length(Hashes),
    etorrent_piece_mgr:add_pieces(
      Id,
      [{PN, Hash, dummy, fetched}
       || {PN, Hash} <- lists:zip(lists:seq(0,L - 1),
				  Hashes)]).

initialize_pieces_from_bitfield(Id, BitField, Hashes) ->
    L = length(Hashes),
    {ok, Set} = etorrent_proto_wire:decode_bitfield(L, BitField),
    F = fun (PN) ->
                case gb_sets:is_element(PN, Set) of
                    true -> fetched;
                    false -> not_fetched
                end
        end,
    Pieces = [{PN, Hash, dummy, F(PN)}
	      || {PN, Hash} <- lists:zip(lists:seq(0, L - 1),
					 Hashes)],
    etorrent_piece_mgr:add_pieces(Id, Pieces).

initialize_pieces_from_disk(_, Id, Hashes) ->
    L = length(Hashes),
    F = fun(PN, Hash) ->
		State = case etorrent_io:check_piece(Id, PN) of
			    {ok, _} -> fetched;
			    wrong_hash -> not_fetched
			end,
		{PN, Hash, dummy, State}
        end,
    etorrent_piece_mgr:add_pieces(
      Id,
      [F(PN, Hash)
       || {PN, Hash} <- lists:zip(lists:seq(0, L - 1),
				  Hashes)]).



