%%
%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Chunk manager of a torrent.
%% <p>This module implement a manager of chunks for the etorrent
%% application. When we download from multiple peers, each peer will have
%% different pieces. Say for instance that A has pieces [1,2] while B has
%% [1,3]. In this case, we can download 2 from A, 3 from B and 1 from
%% either of them.</p>
%% <p>The bittorrent protocol, however, does not transfer
%% pieces. Instead it transfers slices of pieces, 16 Kilobytes in size
%% -- mostly to battle the problem that no other message would be able
%% to get through otherwise. We call these slices for "chunks" and it
%% is the responsibility of the chunk_mgr to keep track of chunks that
%% has not been downloaded yet.</p>
%% <p>A chunk must only be downloaded from one peer at a time in order
%% not to waste bandwidth. Thus we keep track of which peer got a
%% chunk at any given time. If the peer dies, a monitor() keeps track
%% of him, so we can give back all pieces.</p>
%% <p>We systematically select pieces for chunking and then serve
%% chunks to peers. We have the invariant chunked ==
%% someone-is-downloading (almost always, there is an exception if a
%% peer is the only one with a piece and that peer dies). The goal is
%% to "close" a piece as fast as possible when it is chunked by
%% downloading all remaining chunks on it. This in turn will trigger a
%% HAVE message to all peers and we can begin serving that piece to others.</p>
%% <p>The selection criteria is this:
%% <ul>
%%   <li>A peer asks for N chunks. See first if there are chunks among
%% the already chunked pieces that can be used for that peer.</li>
%%   <li>If we exhaust all chunk attempts either because none are
%% eligible or all are assigned, we try to find a new piece to chunkify.</li>
%%   <li>If there is a piece we can chunkify, we use that to serve the
%% peer. If not, we report back to the peer if we are interested. We
%% are interested if there was interesting pieces, but the chunks are
%% currently on assignment to other peers. If no interesting pieces
%% are there, we report back we don't have any interest in the peer.</li>
%% </ul></p>
%% <h4>The endgame:</h4>
%% <p>When there are only chunked pieces left (there are no pieces
%% left we haven't begun fetching), we enter <em>endgame mode</em> in
%% which we randomly shuffle the pieces and ask for the same chunks on
%% all peers. As soon as we get in a chunk, we aggressively CANCEL it
%% at all other places, hoping we waste as little bandwidth as
%% possible. Endgame mode in etorrent usually lasts some 10-30 seconds
%% on a torrent.</p>
%% @end
%%-------------------------------------------------------------------
-module(etorrent_progress).
-behaviour(gen_server).

-include_lib("stdlib/include/ms_transform.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% peer API
-export([start_link/1,
         start_link/5,
         mark_valid/2]).

%% stats API
-export([stats/1,
         num_invalid/1,
         num_unassigned/1,
         num_begun/1,
         num_assigned/1,
         num_stored/1,
         num_valid/1]).

%% gproc registry entries
-export([register_server/1,
         unregister_server/1,
         lookup_server/1,
         await_server/1]).


%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-import(gen_server, [call/2, cast/2]).
-compile({no_auto_import,[monitor/2, error/1]}).
-import(erlang, [monitor/2, error/1]).

-type pieceset()   :: etorrent_pieceset:pieceset().
-type torrent_id() :: etorrent_types:torrent_id().
-type chunk_len() :: etorrent_types:chunk_len().
-type chunk_offset() :: etorrent_types:chunk_offset().
-type piece_index() :: etorrent_types:piece_index().
-type piece_state() :: invalid | unassigned | begun | assigned | stored | valid.
-type serverarg() ::
    {torrentid,   torrent_id()} |
    {chunksize,   chunk_len()} |
    {fetched,     [piece_index()]} |
    {piecesizes,  [{piece_index(), chunk_len()}]} |
    {torrentpid,  pid()} |
    {scarcitypid, pid()} |
    {pendingpid,  pid()}.

-record(pieceprio, {
    tag :: atom(),
    ref :: reference(),
    pieces :: [pos_integer()]}).

-record(state, {
    torrent_id  :: pos_integer(),
    torrent_pid :: pid(),
    chunk_size  :: pos_integer(),
    %% Piece state sets
    pieces_valid      :: pieceset(),
    pieces_unassigned :: pieceset(),
    pieces_begun      :: pieceset(),
    pieces_assigned   :: pieceset(),
    pieces_stored     :: pieceset(),
    %% Chunk sets for pieces
    chunks_assigned :: array(),
    chunks_stored   :: array(),
    %% Piece priority lists
    piece_priority  :: #pieceprio{},
    %% Chunk assignment processes
    pending     = exit(required) :: pid(),
    endgame     = exit(required) :: pid(),
    in_endgame  = exit(required) :: boolean()}).

%% # Piece states
%% As the download of a torrent progresses, and regresses, each piece
%% enters and leaves a sequence of states.
%% 
%% ## Sequence
%% 0. Invalid
%% 1. Unassigned
%% 2. Begun
%% 3. Assigned
%% 4. Stored
%% 5. Valid
%% 
%% ## Invalid
%% By default all pieces are considered as invalid. A piece
%% is invalid if it is not a member of the set of valid pieces
%%
%% ## Unassigned
%% When the chunk server is initialized all invalid pieces enter
%% the Unassigned state. A piece leaves the unassigned state when
%% the piece enters the begun state.
%%
%% ## Begun
%% When the download of a piece has begun the piece enters
%% the begun state. While the piece is in the Begun state it is
%% still considered invalid, but it enables the chunk server
%% prioritize these pieces. A piece leaves the begun state
%% when it enters the Assigned state.
%%
%% ## Assigned
%% When all chunks of the piece has been assigned to be downloaded
%% from a set of peers the piece enters the Assigned state.
%% A piece leaves the Assigned state and reenters the Begun state if
%% a request is marked as dropped before the piece has entered the
%% Stored state.
%%
%% ## Stored
%% When all chunks of a piece in the Assigned state has been marked
%% as stored the piece enters the Stored state. The piece will leave
%% the stored state and enter the Valid state if it is marked as valid.
%%
%% ## Valid
%% A piece enters the valid state from the Stored state.  A piece will
%% never leave the Valid state.
%%
%% # Priority of pieces
%% The chunk server uses the scarcity server to keep an updated
%% list of pieces, ordered by priority, Every time the unassugned
%% piece set is update the piece list need to be updated.
%%
%% ## Begun
%% The piece with the lowest piece index is prioritized over other pieces.
%%
%% ## Unassigned
%% If the chunk server can't find a begun piece it will pick and begin
%% downloading the most scarce piece from the set of unassigned pieces.
%% This set should be relatively large initially and accessed infrequently.
%%
%% # Chunk sets
%% ## Assigned chunks
%% A set of chunks that has not yet been assigned to a peer is
%% associated with each piece. When this set is empty the piece
%% enters the assigned state.
%%
%% ## Stored chunks
%% A set of chunks that has not yet been written to disk is associated
%% with each piece. When this set is empty the piece enters the stored
%% state. 
%%
%% # Dropped requests
%% A request may be dropped in three ways.
%% - calling mark_dropped/3
%% - calling mark_all_dropped/1
%% - the peer crashes
%%
%% If mark_dropped/3 is called the chunk should be removed from
%% the set of open requests and inserted into the set of assigned
%% chunks for the piece.
%%
%% If mark_all_dropped/1 is called all chunks should be removed from
%% the set of open requests and inserted into the chunk sets of each piece.
%%
%% If the peer crashes all chunks should be inserted into the chunk sets
%% of each piece and the peer should be removed from the set of monitored
%% peers.
%%

-spec register_server(torrent_id()) -> true.
register_server(TorrentID) ->
    etorrent_utils:register(server_name(TorrentID)).

-spec unregister_server(torrent_id()) -> true.
unregister_server(TorrentID) ->
    etorrent_utils:unregister(server_name(TorrentID)).

-spec lookup_server(torrent_id()) -> pid().
lookup_server(TorrentID) ->
    etorrent_utils:lookup(server_name(TorrentID)).

-spec await_server(torrent_id()) -> pid().
await_server(TorrentID) ->
    etorrent_utils:await(server_name(TorrentID)).

server_name(TorrentID) ->
    {etorrent, TorrentID, chunk_server}.


%% @doc Start a new torrent progress server
%% @end
-spec start_link([serverarg()]) -> {ok, pid()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).


%% @doc
%% Start a new chunk server for a set of pieces, a subset of the
%% pieces may already have been fetched.
%% @end
start_link(TorrentID, ChunkSize, Fetched, Sizes, TorrentPid) ->
    Args = [
        {torrentid, TorrentID},
        {chunksize, ChunkSize},
        {fetched, Fetched},
        {piecesizes, Sizes},
        {torrentpid, TorrentPid}],
    start_link(Args).

%% @doc
%% Mark a piece as completly stored to disk and validated.
%% @end
-spec mark_valid(pos_integer(), pid()) -> ok.
mark_valid(Piece, SrvPid) ->
    SrvPid ! {mark_valid, Piece},
    ok.


%% @doc Print chunk server statistics
%% @end
-spec stats(torrent_id()) -> ok.
stats(TorrentID) ->
    io:format("Invalid:    ~w~n", [num_invalid(TorrentID)]),
    io:format("Unassigned: ~w~n", [num_unassigned(TorrentID)]),
    io:format("Begun:      ~w~n", [num_begun(TorrentID)]),
    io:format("Assigned:   ~w~n", [num_assigned(TorrentID)]),
    io:format("Stored:     ~w~n", [num_stored(TorrentID)]),
    io:format("Valid:      ~w~n", [num_valid(TorrentID)]).

%% @doc Return the number of invalid pieces
%% @end
-spec num_invalid(torrent_id()) -> non_neg_integer().
num_invalid(TorrentID) ->
    num_state_members(TorrentID, invalid).

%% @doc Return the number of unassigned pieces
-spec num_unassigned(torrent_id()) -> non_neg_integer().
num_unassigned(TorrentID) ->
    num_state_members(TorrentID, unassigned).

%% @doc Return the number of begun pieces
-spec num_begun(torrent_id()) -> non_neg_integer().
num_begun(TorrentID) ->
    num_state_members(TorrentID, begun).

%% @doc Return the number of assigned pieces
-spec num_assigned(torrent_id()) -> non_neg_integer().
num_assigned(TorrentID) ->
    num_state_members(TorrentID, assigned).

%% @doc Return the number of stored pieces
-spec num_stored(torrent_id()) -> non_neg_integer().
num_stored(TorrentID) ->
    num_state_members(TorrentID, stored).

%% @doc Return the number of validated pieces
-spec num_valid(torrent_id()) -> non_neg_integer().
num_valid(TorrentID) ->
    num_state_members(TorrentID, valid).

%% @private
-spec state_members(torrent_id(), piece_state()) -> pieceset().
state_members(TorrentID, Piecestate) ->
    ChunkSrv = lookup_server(TorrentID),
    call(ChunkSrv, {state_members, Piecestate}).

%% @private
-spec num_state_members(torrent_id(), piece_state()) -> integer().
num_state_members(TorrentID, Piecestate) ->
    case Piecestate of
        invalid ->
            Valid = state_members(TorrentID, valid),
            Total = etorrent_pieceset:capacity(Valid),
            Total - etorrent_pieceset:size(Valid);
        _ ->
            Members = state_members(TorrentID, Piecestate),
            etorrent_pieceset:size(Members)
    end.


%% @private
init(Serverargs) ->
    Args = orddict:from_list(Serverargs),
    TorrentID = orddict:fetch(torrentid, Args),
    true = register_server(TorrentID),
    ChunkSize = orddict:fetch(chunksize, Args),
    PiecesValid = orddict:fetch(fetched, Args),
    PieceSizes = orddict:fetch(piecesizes, Args),

    TorrentPid = etorrent_torrent_ctl:await_server(TorrentID),
    _ScarcityPid = etorrent_scarcity:await_server(TorrentID),
    Pending = etorrent_pending:await_server(TorrentID),
    Endgame = etorrent_endgame:await_server(TorrentID),
    ok = etorrent_pending:receiver(self(), Pending),

    NumPieces = length(PieceSizes),
    PiecesNone = etorrent_pieceset:from_list([], NumPieces),

    %% Initialize a full chunkset for all pieces that are left to download
    %% but don't mark them as begun before a chunk has been deleted from
    %% any of the chunksets.
    %% Initialize an empty chunkset for all valid pieces.
    AllIndexes = lists:seq(0, NumPieces - 1),
    AllPieces = etorrent_pieceset:from_list(AllIndexes, NumPieces),
    PiecesInvalid = etorrent_pieceset:difference(AllPieces, PiecesValid),
    InvalidList = etorrent_pieceset:to_list(PiecesInvalid),
    ValidList = etorrent_pieceset:to_list(PiecesValid),
    States = [{N, false} || N <- InvalidList] ++ [{N, true} || N <- ValidList],
    ChunkList = [begin
        Size = orddict:fetch(N, PieceSizes),
        Set = case IsValid of
            false -> etorrent_chunkset:new(Size, ChunkSize);
            true  -> etorrent_chunkset:from_list(Size, ChunkSize, [])
        end,
        {N, Set}
    end || {N, IsValid} <- lists:sort(States)],
    ChunkSets = array:from_orddict(ChunkList),

    PiecePriority = init_priority(TorrentID, unassigned, PiecesInvalid),

    InitState = #state{
        torrent_id=TorrentID,
        torrent_pid=TorrentPid,
        chunk_size=ChunkSize,
        %% All Valid pieces stay Valid
        pieces_valid=PiecesValid,
        %% All Invalid pieces are Unassigned
        pieces_unassigned=PiecesInvalid,
        %% No pieces have are yet Begun, Assigned or Stored
        pieces_begun=PiecesNone,
        pieces_assigned=PiecesNone,
        pieces_stored=PiecesNone,
        %% Initially, the sets of assigned and stored chunks are equal
        chunks_assigned=ChunkSets,
        chunks_stored=ChunkSets,
        piece_priority=PiecePriority,
        pending=Pending,
        endgame=Endgame,
        in_endgame=false},
    {ok, InitState}.


%% Ignore all chunk requests while we are in endgame
handle_call({chunk, {request, _, _, _}}, _, State) when State#state.in_endgame ->
    {reply, {ok, assigned}, State};

handle_call({chunk, {request, Numchunks, Peerset, PeerPid}}, _, State) ->
    #state{
        torrent_id=TorrentID,
        pieces_valid=Valid,
        pieces_unassigned=Unassigned,
        pieces_begun=Begun,
        pieces_assigned=Assigned,
        chunks_assigned=AssignedChunks,
        piece_priority=PiecePriority,
        pending=Pending,
        endgame=Endgame} = State,

    %% If this peer has any pieces that we have begun downloading, pick
    %% one of those pieces over any unassigned pieces.
    Optimal = etorrent_pieceset:intersection(Peerset, Begun),
    HasOptimal = not etorrent_pieceset:is_empty(Optimal),

    %% If this peer doesn't have any pieces that we have already begun
    %% downloading we should consider any unassigned pieces that this
    %% peer has available.
    {SubOptimal, HasSuboptimal} = case HasOptimal of
        true ->
            {false, false};
        false ->
            ISubOptimal = etorrent_pieceset:intersection(Peerset, Unassigned),
            IHasSubOptimal = not etorrent_pieceset:is_empty(ISubOptimal),
            {ISubOptimal, IHasSubOptimal}
    end,
    
    %% We target pieces of different states depending upon what
    %% the peer has available and the current piece states.
    Targetstate = if
        HasOptimal -> begun;
        HasSuboptimal -> unassigned;
        true -> none
    end,

    PieceIndex = case Targetstate of
        %% Assume that the peer has pieces that are interesting but
        %% all requests for these pieces have been assigned.
        none ->
            assigned;
        %% One or more that we are already downloading
        begun ->
            etorrent_pieceset:min(Optimal);
        %% None that we are not already downloading
        %% but one ore more that we would want to download
        unassigned ->
            #pieceprio{pieces=UnassignedPriolist} = PiecePriority,
            etorrent_pieceset:first(UnassignedPriolist, SubOptimal)
    end,

    case PieceIndex of
        %% Check if we are in endgame now.
        assigned ->
            BeginEndgame = etorrent_pieceset:is_empty(Unassigned)
                andalso etorrent_pieceset:is_empty(Begun),
            case BeginEndgame of
                false ->
                    {reply, {ok, assigned}, State};
                true ->
                    ok = etorrent_pending:receiver(Endgame, Pending),
                    ok = etorrent_endgame:activate(Endgame),
                    NewState = State#state{in_endgame=true},
                    {reply, {ok, assigned}, NewState}
            end;
        Index ->
            Chunkset = array:get(Index, AssignedChunks),
            Offsets = etorrent_chunkset:min(Chunkset, Numchunks),
            Chunks = [{Index, Offs, Len} || {Offs, Len} <- Offsets],
            NewChunkset = etorrent_chunkset:delete(Offsets, Chunkset),
            NewAssignedChunks = array:set(Index, NewChunkset, AssignedChunks),
            ok = etorrent_chunkstate:assigned(Chunks, PeerPid, Pending),

            %% We need to consider four transitions at this point:
            %% Unassigned -> Begun
            %% Unassigned -> Assigned
            %% Begun -> Begun
            %% Begun -> Assigned
            %%
            %% The piece may have gone directly from Unassigned to Assigned.
            %% Check if it has been assigned before making any transitions.
            Transitionstate = case etorrent_chunkset:is_empty(NewChunkset) of
                true -> assigned;
                false -> begun
            end,
            %% Update piece sets and keep track of which sets were updated
            case {Targetstate, Transitionstate} of
                {unassigned, begun} ->
                    NewUnassigned = etorrent_pieceset:delete(Index, Unassigned),
                    NewBegun = etorrent_pieceset:insert(Index, Begun),
                    NewAssigned = Assigned,
                    UnassignedUpdated = true;
                {unassigned, assigned} ->
                    NewUnassigned = etorrent_pieceset:delete(Index, Unassigned),
                    NewBegun = Begun,
                    NewAssigned = etorrent_pieceset:insert(Index, Assigned),
                    UnassignedUpdated = true;
                {begun, begun} ->
                    NewUnassigned = Unassigned,
                    NewBegun = Begun,
                    NewAssigned = Assigned,
                    UnassignedUpdated = false;
                {begun, assigned} ->
                    NewUnassigned = Unassigned,
                    NewBegun = etorrent_pieceset:delete(Index, Begun),
                    NewAssigned = etorrent_pieceset:insert(Index, Assigned),
                    UnassignedUpdated = false
            end,

            %% Only update the piece priority lists if a piece in the
            %% unassigned state was removed because of this request.
            NewPiecePriority = case UnassignedUpdated of
                false -> PiecePriority;
                true  -> update_priority(TorrentID, PiecePriority, NewUnassigned)
            end,

            NewState = State#state{
                pieces_unassigned=NewUnassigned,
                pieces_begun=NewBegun,
                pieces_assigned=NewAssigned,
                chunks_assigned=NewAssignedChunks,
                piece_priority=NewPiecePriority},
            {reply, {ok, Chunks}, NewState}
    end;

handle_call({state_members, Piecestate}, _, State) ->
    Stateset = case Piecestate of
        unassigned -> State#state.pieces_unassigned;
        begun -> State#state.pieces_begun;
        assigned -> State#state.pieces_assigned;
        stored -> State#state.pieces_stored;
        valid -> State#state.pieces_valid
    end,
    {reply, Stateset, State}.


%% @private
handle_cast(_, State) ->
    {stop, not_implemented, State}.


%% @private
handle_info({piece, {valid, Index}}, State) ->
    #state{
        pieces_stored=Stored,
        pieces_valid=Valid} = State,
    IsStored = etorrent_pieceset:is_member(Index, Stored),
    IsValid = etorrent_pieceset:is_member(Index, Valid),
    Piecestate = if
        IsValid -> valid;
        IsStored -> stored;
        true -> not_stored
    end,
    case Piecestate of
        valid -> {noreply, State};
        not_stored -> {noreply, State};
        stored ->
            NewStored = etorrent_pieceset:delete(Index, Stored),
            NewValid = etorrent_pieceset:insert(Index, Valid),
            NewState = State#state{
                pieces_stored=NewStored,
                pieces_valid=NewValid},
            {noreply, NewState}
    end;


handle_info({chunk, {stored, Index, Offset, Length, Pid}}, State) ->
    #state{
        torrent_pid=TorrentPid,
        pieces_assigned=Assigned,
        pieces_stored=Stored,
        chunks_stored=ChunksStored,
        in_endgame=InEndgame,
        endgame=Endgame} = State,

    %% Update the set of chunks in the piece that has been written to disk.
    Chunks = array:get(Index, ChunksStored),
    NewChunks = etorrent_chunkset:delete(Offset, Length, Chunks),
    NewChunksStored = array:set(Index, NewChunks, ChunksStored),
    
    %% If we are in endgame, forward all stored notifications to
    %% the endgame process to ensure that it is not requested again.
    InEndgame andalso etorrent_chunkstate:stored(Index, Offset, Length, Pid, Endgame),

    %% If all chunks in this piece has been written to disk we want
    %% to move the piece from the Assigned state to the Stored state.
    %% The piece must be Assigned before entering the Stored state
    %% so we don't need to consider a transition from Begun to Stored.
    Wasassigned = etorrent_pieceset:is_member(Index, Assigned),
    Wasstored = etorrent_chunkset:is_empty(NewChunks),
    Piecestate = if
        Wasassigned -> assigned;
        true -> begun
    end,
    NewState = case Piecestate of
        %% Begun -> Begun
        begun ->
            State#state{chunks_stored=NewChunksStored};
        %% Assigned -> Assigned
        assigned when not Wasstored ->
            State#state{chunks_stored=NewChunksStored};
        %% Assigned -> Stored
        assigned when Wasstored ->
            ok = etorrent_piecestate:stored(Index, TorrentPid),
            NewAssigned = etorrent_pieceset:delete(Index, Assigned),
            NewStored = etorrent_pieceset:insert(Index, Stored),
            IState = State#state{
                chunks_stored=NewChunksStored,
                pieces_assigned=NewAssigned,
                pieces_stored=NewStored},
            IState
    end,
    {noreply, NewState};

handle_info({chunk, {dropped, Piece, Offset, Length, Peerpid}}, State)
when State#state.in_endgame ->
    #state{endgame=Endgame} = State,
    ok = etorrent_chunkstate:dropped(Piece, Offset, Length, Peerpid, Endgame),
    {noreply, State};

handle_info({chunk, {dropped, Piece, Offset, Length, _}}, State) ->
    #state{
        torrent_id=TorrentID,
        pieces_begun=Begun,
        pieces_assigned=Assigned,
        chunks_assigned=AssignedChunks} = State,

     %% Add the chunk back to the chunkset of the piece.
     Chunks = array:get(Piece, AssignedChunks),
     NewChunks = etorrent_chunkset:insert(Offset, Length, Chunks),
     NewAssignedChunks = array:set(Piece, NewChunks, AssignedChunks),

     %% Assigned -> Begun
     NewAssigned = etorrent_pieceset:delete(Piece, Assigned),
     NewBegun = etorrent_pieceset:insert(Piece, Begun),
 
     NewState = State#state{
         pieces_begun=NewBegun,
         pieces_assigned=NewAssigned,
         chunks_assigned=NewAssignedChunks},
    {noreply, NewState};


handle_info({scarcity, Ref, Tag, Piecelist}, State) ->
    #state{piece_priority=PiecePriority} = State,
    %% Verify that the tag is valid before verifying the reference
    #pieceprio{ref=PrioRef} = PiecePriority,
    %% Verify that the reference belongs to the active subscription
    %% If not, drop the update and hope that it was a stray one.
    NewState = case Ref of
        PrioRef ->
            NewPriority = PiecePriority#pieceprio{pieces=Piecelist},
            State#state{piece_priority=NewPriority};
        _ ->
            State
    end,
    {noreply, NewState}.


%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

init_priority(TorrentID, Tag, Pieceset) ->
    {ok, Ref, List} = etorrent_scarcity:watch(TorrentID, Tag, Pieceset),
    #pieceprio{ref=Ref, tag=Tag, pieces=List}.

update_priority(TorrentID, Pieceprio, Pieceset) ->
    #pieceprio{ref=Ref, tag=Tag} = Pieceprio,
    ok = etorrent_scarcity:unwatch(TorrentID, Ref),
    {ok, NewRef, NewList} = etorrent_scarcity:watch(TorrentID, Tag, Pieceset),
    #pieceprio{ref=NewRef, tag=Tag, pieces=NewList}.


-ifdef(TEST).
-define(progress, ?MODULE).
-define(scarcity, etorrent_scarcity).
-define(timer, etorrent_timer).
-define(pending, etorrent_pending).
-define(chunkstate, etorrent_chunkstate).
-define(piecestate, etorrent_piecestate).
-define(endgame, etorrent_endgame).


chunk_server_test_() ->
    {setup, local,
        fun() ->
            application:start(gproc),
            etorrent_torrent_ctl:register_server(testid()) end,
        fun(_) -> application:stop(gproc) end,
    {foreach, local,
        fun setup_env/0,
        fun teardown_env/1,
    [?_test(lookup_registered_case()),
     ?_test(unregister_case()),
     ?_test(register_two_case()),
     ?_test(double_check_env()),
     ?_test(assigned_case()),
     ?_test(assigned_valid_case()),
     ?_test(request_one_case()),
     ?_test(mark_dropped_case()),
     ?_test(mark_all_dropped_case()),
     ?_test(drop_none_on_exit_case()),
     ?_test(drop_all_on_exit_case()),
     ?_test(marked_stored_not_dropped_case()),
     ?_test(mark_valid_not_stored_case()),
     ?_test(mark_valid_stored_case()),
     ?_test(all_stored_marks_stored_case()),
     ?_test(get_all_request_case()),
     ?_test(unassigned_to_assigned_case()),
     ?_test(trigger_endgame_case())
     ]}}.


testid() -> 2.

setup_env() ->
    Sizes = [{0, 2}, {1, 2}, {2, 2}],
    Valid = etorrent_pieceset:empty(length(Sizes)),
    {ok, Time} = ?timer:start_link(queue),
    {ok, PPid} = ?pending:start_link(testid()),
    {ok, EPid} = ?endgame:start_link(testid()),
    {ok, SPid} = ?scarcity:start_link(testid(), Time, 8),
    {ok, CPid} = ?progress:start_link(testid(), 1, Valid, Sizes, self()),
    ok = ?pending:register(PPid),
    ok = ?pending:receiver(CPid, PPid),
    {Time, EPid, PPid, SPid, CPid}.

scarcity() -> ?scarcity:lookup_server(testid()).
pending()  -> ?pending:lookup_server(testid()).
progress() -> ?progress:lookup_server(testid()).
endgame()  -> ?endgame:lookup_server(testid()).

teardown_env({Time, EPid, PPid, SPid, CPid}) ->
    ok = etorrent_utils:shutdown(Time),
    ok = etorrent_utils:shutdown(EPid),
    ok = etorrent_utils:shutdown(PPid),
    ok = etorrent_utils:shutdown(SPid),
    ok = etorrent_utils:shutdown(CPid).

double_check_env() ->
    ?assert(is_pid(scarcity())),
    ?assert(is_pid(pending())),
    ?assert(is_pid(progress())),
    ?assert(is_pid(endgame())).

lookup_registered_case() ->
    ?assertEqual(true, ?progress:register_server(0)),
    ?assertEqual(self(), ?progress:lookup_server(0)).

unregister_case() ->
    ?assertEqual(true, ?progress:register_server(1)),
    ?assertEqual(true, ?progress:unregister_server(1)),
    ?assertError(badarg, ?progress:lookup_server(1)).

register_two_case() ->
    Main = self(),
    {Pid, Ref} = erlang:spawn_monitor(fun() ->
        etorrent_utils:expect(go),
        true = ?pending:register_server(20),
        Main ! registered,
        etorrent_utils:expect(die)
    end),
    Pid ! go,
    etorrent_utils:expect(registered),
    ?assertError(badarg, ?pending:register_server(20)),
    Pid ! die,
    etorrent_utils:wait(Ref).

assigned_case() ->
    Has = etorrent_pieceset:from_list([], 3),
    Ret = ?chunkstate:request(1, Has, progress()),
    ?assertEqual({ok, assigned}, Ret).

assigned_valid_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    _   = ?chunkstate:request(2, Has, progress()),
    ok  = ?chunkstate:stored(0, 0, 1, self(), progress()),
    ok  = ?chunkstate:stored( 0, 1, 1, self(), progress()),
    ok  = ?piecestate:valid(0, progress()),
    Ret = ?chunkstate:request(2, Has, progress()),
    ?assertEqual({ok, assigned}, Ret).

request_one_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    Ret = ?chunkstate:request(1, Has, progress()),
    ?assertEqual({ok, [{0, 0, 1}]}, Ret).

mark_dropped_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    {ok, [{0, 0, 1}]} = ?chunkstate:request(1, Has, progress()),
    {ok, [{0, 1, 1}]} = ?chunkstate:request(1, Has, progress()),
    ok  = ?chunkstate:dropped(0, 0, 1, self(), progress()),
    Ret = ?chunkstate:request(1, Has, progress()),
    ?assertEqual({ok, [{0, 0, 1}]}, Ret).

mark_all_dropped_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunkstate:request(1, Has, progress())),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunkstate:request(1, Has, progress())),
    ok = ?chunkstate:dropped(self(), pending()),
    ok = ?chunkstate:dropped([{0,0,1},{0,1,1}], self(), progress()),
    etorrent_utils:ping(pending()),
    etorrent_utils:ping(progress()),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunkstate:request(1, Has, progress())),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunkstate:request(1, Has, progress())).

drop_all_on_exit_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() ->
        ok = ?pending:register(pending()),
        {ok, [{0, 0, 1}]} = ?chunkstate:request(1, Has, progress()),
        {ok, [{0, 1, 1}]} = ?chunkstate:request(1, Has, progress())
    end),
    etorrent_utils:wait(Pid),
    timer:sleep(100),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunkstate:request(1, Has, progress())),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunkstate:request(1, Has, progress())).

drop_none_on_exit_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() ->
        ok = ?pending:register(pending())
    end),
    etorrent_utils:wait(Pid),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunkstate:request(1, Has, progress())),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunkstate:request(1, Has, progress())).

marked_stored_not_dropped_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() ->
        ok = ?pending:register(pending()),
        {ok, [{0, 0, 1}]} = ?chunkstate:request(1, Has, progress()),
        ok = ?chunkstate:stored(0, 0, 1, self(), progress()),
        ok = ?chunkstate:stored(0, 0, 1, self(), pending())
    end),
    etorrent_utils:wait(Pid),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunkstate:request(1, Has, progress())).

mark_valid_not_stored_case() ->
    Ret = ?piecestate:valid(0, progress()),
    ?assertEqual(ok, Ret).

mark_valid_stored_case() ->
    Has = etorrent_pieceset:from_list([0,1], 3),
    {ok, [{0, 0, 1}]} = ?chunkstate:request(1, Has, progress()),
    {ok, [{0, 1, 1}]} = ?chunkstate:request(1, Has, progress()),
    ok  = ?chunkstate:stored(0, 0, 1, self(), progress()),
    ok  = ?chunkstate:stored(0, 1, 1, self(), progress()),
    ?assertEqual(ok, ?piecestate:valid(0, progress())),
    ?assertEqual(ok, ?piecestate:valid(0, progress())).

all_stored_marks_stored_case() ->
    Has = etorrent_pieceset:from_list([0,1], 3),
    {ok, [{0, 0, 1}]} = ?chunkstate:request(1, Has, progress()),
    {ok, [{0, 1, 1}]} = ?chunkstate:request(1, Has, progress()),
    ?assertMatch({ok, [{1, 0, 1}]}, ?chunkstate:request(1, Has, progress())),
    ?assertMatch({ok, [{1, 1, 1}]}, ?chunkstate:request(1, Has, progress())).

get_all_request_case() ->
    Has = etorrent_pieceset:from_list([0,1,2], 3),
    {ok, [{0, 0, 1}]} = ?chunkstate:request(1, Has, progress()),
    {ok, [{0, 1, 1}]} = ?chunkstate:request(1, Has, progress()),
    {ok, [{1, 0, 1}]} = ?chunkstate:request(1, Has, progress()),
    {ok, [{1, 1, 1}]} = ?chunkstate:request(1, Has, progress()),
    {ok, [{2, 0, 1}]} = ?chunkstate:request(1, Has, progress()),
    {ok, [{2, 1, 1}]} = ?chunkstate:request(1, Has, progress()),
    ?assertEqual({ok, assigned}, ?chunkstate:request(1, Has, progress())).

unassigned_to_assigned_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    {ok, [{0,0,1}, {0,1,1}]} = ?chunkstate:request(2, Has, progress()),
    ?assertEqual({ok, assigned}, ?chunkstate:request(1, Has, progress())).

trigger_endgame_case() ->
    %% Endgame should be triggered if all pieces have been begun and all
    %% remaining chunk requests have been assigned to peer processes.
    Has = etorrent_pieceset:from_list([0,1,2], 3),
    {ok, [{0, 0, 1}, {0, 1, 1}]} = ?chunkstate:request(2, Has, progress()),
    {ok, [{1, 0, 1}, {1, 1, 1}]} = ?chunkstate:request(2, Has, progress()),
    {ok, [{2, 0, 1}, {2, 1, 1}]} = ?chunkstate:request(2, Has, progress()),
    {ok, assigned} = ?chunkstate:request(1, Has, progress()),
    ?assert(?endgame:is_active(endgame())),
    {ok, assigned} = ?chunkstate:request(1, Has, progress()),
    ?chunkstate:dropped(0, 0, 1, self(), progress()),
    {ok, assigned} = ?chunkstate:request(1, Has, progress()),
    %% Assert that we can aquire only this request from the endgame process
    ?assertEqual({ok, [{0, 0, 1}]}, ?chunkstate:request(1, Has, endgame())),
    ?assertEqual({ok, assigned}, ?chunkstate:request(1, Has, endgame())),
    %% Mark all requests as fetched.
    ok = ?chunkstate:fetched(0, 0, 1, self(), endgame()),
    ok = ?chunkstate:fetched(0, 1, 1, self(), endgame()),
    ok = ?chunkstate:fetched(1, 0, 1, self(), endgame()),
    ok = ?chunkstate:fetched(1, 1, 1, self(), endgame()),
    ok = ?chunkstate:fetched(2, 0, 1, self(), endgame()),
    ok = ?chunkstate:fetched(2, 1, 1, self(), endgame()),
    ?assertEqual(ok, etorrent_utils:ping(endgame())).

-endif.
