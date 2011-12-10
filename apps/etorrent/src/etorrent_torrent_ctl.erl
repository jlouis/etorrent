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
-define(CHECK_WAIT_TIME, 3000).


%% API
-export([start_link/3,
         completed/1,
         check_torrent/1,
         valid_pieces/1]).

%% gproc registry entries
-export([register_server/1,
         lookup_server/1,
         await_server/1]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, initializing/2, started/2,
         handle_sync_event/4, handle_info/3, terminate/3,
         code_change/4]).

-type bcode() :: etorrent_types:bcode().
-type torrentid() :: etorrent_types:torrent_id().
-type pieceset() :: etorrent_pieceset:pieceset().
-type pieceindex() :: etorrent_types:piece_index().
-record(state, {
    id          :: integer(),    % Index of this torrent
    torrent     :: bcode(),      % Parsed torrent file
    valid       :: pieceset(),   % A set of the valid pieces for this torrent
    hashes      :: binary(),     % Piece hashes
    info_hash   :: binary(),     % Infohash of torrent file
    peer_id     :: binary(),
    parent_pid  :: pid(),        % Parent pid @todo remove this
    progress    :: pid(),
    pending     :: pid(),
    endgame     :: pid()}).



-spec register_server(torrentid()) -> true.
register_server(TorrentID) ->
    etorrent_utils:register(server_name(TorrentID)).

-spec lookup_server(torrentid()) -> pid().
lookup_server(TorrentID) ->
    etorrent_utils:lookup(server_name(TorrentID)).

-spec await_server(torrentid()) -> pid().
await_server(TorrentID) ->
    etorrent_utils:await(server_name(TorrentID)).

server_name(TorrentID) ->
    {etorrent, TorrentID, control}.

%% @doc Start the server process
-spec start_link(integer(), {bcode(), string(), binary()}, binary()) ->
        {ok, pid()} | ignore | {error, term()}.
start_link(Id, {Torrent, TorrentFile, TorrentIH}, PeerId) ->
    gen_fsm:start_link(?MODULE, [self(), Id, {Torrent, TorrentFile, TorrentIH}, PeerId], []).

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

%% @doc Get the set of valid pieces for this torrent
%% @end
-spec valid_pieces(pid()) -> {ok, pieceset()}.
valid_pieces(Pid) ->
    gen_fsm:sync_send_all_state_event(Pid, valid_pieces).


%% ====================================================================

%% @private
init([Parent, Id, {Torrent, TorrentFile, TorrentIH}, PeerId]) ->
    register_server(Id),
    etorrent_table:new_torrent(TorrentFile, TorrentIH, Parent, Id),
    HashList = etorrent_metainfo:get_pieces(Torrent),
    Hashes   = hashes_to_binary(HashList),
    InitState = #state{
        id=Id,
        torrent=Torrent,
        info_hash=TorrentIH,
        peer_id=PeerId,
        parent_pid=Parent,
        hashes=Hashes},
    {ok, initializing, InitState, 0}.

%% @private
%% @todo Split and simplify this monster function
initializing(timeout, #state{id=Id, torrent=Torrent, hashes=Hashes} = S0) ->
    Pending  = etorrent_pending:await_server(Id),
    Endgame  = etorrent_endgame:await_server(Id),
    S = S0#state{
        pending=Pending,
        endgame=Endgame},

    case etorrent_table:acquire_check_token(Id) of
        false ->
            {next_state, initializing, S, ?CHECK_WAIT_TIME};
        true ->
            %% @todo: Try to coalesce some of these operations together.

            %% Read the torrent, check its contents for what we are missing
            etorrent_table:statechange_torrent(Id, checking),
            etorrent_event:checking_torrent(Id),
            ValidPieces = read_and_check_torrent(Id, Hashes),
            Left = calculate_amount_left(Id, ValidPieces, Torrent),
            NumberOfPieces = etorrent_pieceset:capacity(ValidPieces),
            {AlltimeUp,
             AlltimeDown} = query_up_down_state(S#state.id),

            %% Add a torrent entry for this torrent.
            ok = etorrent_torrent:new(
                   Id,
                   {{uploaded, 0},
                    {downloaded, 0},
                    {all_time_uploaded, AlltimeUp},
                    {all_time_downloaded, AlltimeDown},
                    {left, Left},
                    {total, etorrent_metainfo:get_length(Torrent)},
                    {is_private, etorrent_metainfo:is_private(Torrent)},
                    {pieces, ValidPieces}},
                   NumberOfPieces),

            %% Start the progress manager
            {ok, ProgressPid} =
                etorrent_torrent_sup:start_progress(
                  S#state.parent_pid,
                  Id,
                  Torrent,
                  ValidPieces),

            %% Update the tracking map. This torrent has been started.
            %% Altering this state marks the point where we will accept
            %% Foreign connections on the torrent as well.
            etorrent_table:statechange_torrent(Id, started),
            etorrent_event:started_torrent(Id),

            %% Start the tracker
            {ok, _TrackerPid} =
                etorrent_torrent_sup:start_child_tracker(
                  S#state.parent_pid,
                  etorrent_metainfo:get_url(Torrent),
                  S#state.info_hash,
                  S#state.peer_id,
                  Id),

            NewState = S#state{valid=ValidPieces, progress = ProgressPid },
            {next_state, started, NewState}
    end.

query_up_down_state(Id) ->
    case etorrent_fast_resume:query_state(Id) of
        unknown -> {0,0};
        {value, PL} ->
            {proplists:get_value(uploaded, PL),
             proplists:get_value(downloaded, PL)}
    end.

%% @private
started(check_torrent, State) ->
    #state{id=TorrentID, valid=ValidPieces, hashes=Hashes} = State,
    NumPieces = etorrent_pieceset:capacity(ValidPieces),
    Indexes =  etorrent_pieceset:to_list(etorrent_pieceset:full(NumPieces)),
    case [I || I <- Indexes, not is_valid_piece(TorrentID, I, Hashes)] of
        [] -> ignore;
        Invalid when is_list(Invalid) ->
            lager:info("Errornous piece: ~b", [Invalid]),
            ignore
    end,
    {next_state, started, State};

started(completed, #state{id=Id} = S) ->
    etorrent_event:completed_torrent(Id),
    Pid = etorrent_tracker_communication:lookup_server(Id),
    etorrent_tracker_communication:completed(Pid),
    {next_state, started, S}.

%% @private
handle_event(Msg, SN, S) ->
    io:format("Problem: ~p~n", [Msg]),
    {next_state, SN, S}.

%% @private
handle_sync_event(valid_pieces, _, StateName, State) ->
    #state{valid=Valid} = State,
    {reply, {ok, Valid}, StateName, State}.

%% @private
%% Tell the controller we have stored an index for this torrent file
%% The controller will update internal state and inform others
handle_info({piece, {stored, Index}}, started, State) ->
    #state{id=TorrentID, hashes=Hashes, progress=Progress, valid=ValidPieces} = State,
    Piecehash = fetch_hash(Index, Hashes),
    case etorrent_io:check_piece(TorrentID, Index, Piecehash) of
        {ok, PieceSize} ->
            Peers = etorrent_peer_control:lookup_peers(TorrentID),
            ok = etorrent_torrent:statechange(TorrentID, [{subtract_left, PieceSize}]),
            ok = etorrent_piecestate:valid(Index, Peers),
            ok = etorrent_piecestate:valid(Index, Progress),
            NewValidState = etorrent_pieceset:insert(Index, ValidPieces),
            {next_state, started, State#state { valid = NewValidState }};
        wrong_hash ->
            Peers = etorrent_peer_control:lookup_peers(TorrentID),
            ok = etorrent_piecestate:invalid(Index, Progress),
            ok = etorrent_piecestate:unassigned(Index, Peers),
            {next_state, started, State}
    end;
handle_info(Info, StateName, State) ->
    lager:error("Unknown handle_info event: ~p", [Info]),
    {next_state, StateName, State}.


%% @private
terminate(_Reason, _StateName, _S) ->
    ok.

%% @private
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%% --------------------------------------------------------------------

%% @todo Does this function belong here?
calculate_amount_left(TorrentID, Valid, Torrent) ->
    Total = etorrent_metainfo:get_length(Torrent),
    Indexes = etorrent_pieceset:to_list(Valid),
    Sizes = [begin
        {ok, Size} = etorrent_io:piece_size(TorrentID, I),
        Size
    end || I <- Indexes],
    Downloaded = lists:sum(Sizes),
    Total - Downloaded.


% @doc Create an initial pieceset() for the torrent.
% <p>Given a TorrentID and a binary of the Hashes of the torrent,
%   form a `pieceset()' by querying the fast_resume system. If the fast resume
%   system knows what is going on, use that information. Otherwise, form all possible
%   pieces, but filter them through a correctness checker.</p>
% @end
-spec read_and_check_torrent(integer(), binary()) -> pieceset().
read_and_check_torrent(TorrentID, Hashes) ->
    ok = etorrent_io:allocate(TorrentID),
    Numpieces = num_hashes(Hashes),
    %% Check the contents of the torrent, updates the state of the piecemap
    case etorrent_fast_resume:query_state(TorrentID) of
        {value, PL} ->
            case proplists:get_value(state, PL) of
                seeding ->
                    etorrent_pieceset:full(Numpieces);
                {bitfield, Bin} ->
                    etorrent_pieceset:from_binary(Bin, Numpieces)
            end;
        unknown ->
            All = etorrent_pieceset:full(Numpieces),
            filter_pieces(TorrentID, All, Hashes)
    end.



% @doc Filter a pieceset() w.r.t data on disk.
% <p>Given a set of pieces to check, `ToCheck', check each piece in there for validity.
%  return a pieceset() where all invalid pieces have been filtered out.</p>
% @end
-spec filter_pieces(torrentid(), pieceset(), binary()) -> pieceset().
filter_pieces(TorrentID, ToCheck, Hashes) ->
    Indexes = etorrent_pieceset:to_list(ToCheck),
    ValidIndexes = [I || I <- Indexes, is_valid_piece(TorrentID, I, Hashes)],
    Numpieces = etorrent_pieceset:capacity(ToCheck),
    etorrent_pieceset:from_list(ValidIndexes, Numpieces).

-spec is_valid_piece(torrentid(), pieceindex(), binary()) -> boolean().
is_valid_piece(TorrentID, Index, Hashes) ->
    Hash = fetch_hash(Index, Hashes),
    case etorrent_io:check_piece(TorrentID, Index, Hash) of
        {ok, _}    -> true;
        wrong_hash -> false
    end.


-spec hashes_to_binary([<<_:160>>]) -> binary().
hashes_to_binary(Hashes) ->
    hashes_to_binary(Hashes, <<>>).

hashes_to_binary([], Acc) ->
    Acc;
hashes_to_binary([H=(<<_:160>>)|T], Acc) ->
    hashes_to_binary(T, <<Acc/binary, H/binary>>).

fetch_hash(Piece, Hashes) ->
    Offset = 20 * Piece,
    case Hashes of
        <<_:Offset/binary, Hash:20/binary, _/binary>> -> Hash;
        _ -> erlang:error(badarg)
    end.

num_hashes(Hashes) ->
    byte_size(Hashes) div 20.


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

hashes_to_binary_test_() ->
    Input = [<<1:160>>, <<2:160>>, <<3:160>>],
    Bin = hashes_to_binary(Input),
    [?_assertEqual(<<1:160>>, fetch_hash(0, Bin)),
     ?_assertEqual(<<2:160>>, fetch_hash(1, Bin)),
     ?_assertEqual(<<3:160>>, fetch_hash(2, Bin)),
     ?_assertEqual(3, num_hashes(Bin)),
     ?_assertError(badarg, fetch_hash(-1, Bin)),
     ?_assertError(badarg, fetch_hash(3, Bin))].

-endif.
