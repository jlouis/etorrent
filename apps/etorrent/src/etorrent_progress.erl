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

-include("log.hrl").

-include_lib("stdlib/include/ms_transform.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% peer API
-export([start_link/5,
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
-export([register_chunk_server/1,
         unregister_chunk_server/1,
         lookup_chunk_server/1,
         await_chunk_server/1,
         register_peer/1]).


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
    prio_begun      :: #pieceprio{},
    prio_unassigned :: #pieceprio{},
    %% Chunk assignment processes
    pending   :: pid(),
    assigning :: pid()}).

-define(in_endgame(State), (State#state.assigning == self())).
-define(is_assigning(State, Pid), (State#state.assigning == Pid)).

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
%% list of pieces, ordered by priority, for two subsets of the
%% pieces in a torrent. Every time these piece sets are update
%% these piece lists need to be updated.
%%
%% ## Begun
%% The chunk server is biased towards choosing pieces that we are
%% already downloading. This set should be relatively small but is
%% accessed frequently during a download.
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

-spec register_chunk_server(torrent_id()) -> true.
register_chunk_server(TorrentID) ->
    gproc:reg({n, l, chunk_server_key(TorrentID)}).

-spec unregister_chunk_server(torrent_id()) -> true.
unregister_chunk_server(TorrentID) ->
    gproc:unreg({n, l, chunk_server_key(TorrentID)}).

-spec lookup_chunk_server(torrent_id()) -> pid().
lookup_chunk_server(TorrentID) ->
    gproc:lookup_pid({n, l, chunk_server_key(TorrentID)}).

-spec await_chunk_server(torrent_id()) -> pid().
await_chunk_server(TorrentID) ->
    Name = {n, l, chunk_server_key(TorrentID)},
    {Pid, undefined} = gproc:await(Name, 5000),
    Pid.

-spec register_peer(torrent_id()) -> true.
register_peer(TorrentID) ->
    ChunkSrv = lookup_chunk_server(TorrentID),
    call(ChunkSrv, {register_peer, self()}).

chunk_server_key(TorrentID) ->
    {etorrent, TorrentID, chunk_server}.


%% @doc
%% Start a new chunk server for a set of pieces, a subset of the
%% pieces may already have been fetched.
%% @end
start_link(TorrentID, ChunkSize, Fetched, Sizes, TorrentPid) ->
    Args = [TorrentID, ChunkSize, Fetched, Sizes, TorrentPid],
    gen_server:start_link(?MODULE, Args, []).

%% @doc
%% Mark a piece as completly stored to disk and validated.
%% @end
-spec mark_valid(pos_integer(), pid()) -> ok.
mark_valid(Piece, SrvPid) ->
    SrvPid ! {mark_valid, Piece},
    ok.


%% @doc
%% Request a unique set of chunks from the server.
%% @end
-spec request_chunks(torrent_id(), pieceset(), pos_integer()) ->
    {ok, list({piece_index(), chunk_offset(), chunk_len()})}
    | {ok, not_interested | assigned}.
request_chunks(TorrentID, Pieceset, Numchunks) ->
    ChunkSrv = lookup_chunk_server(TorrentID),
    call(ChunkSrv, {request_chunks, self(), Pieceset, Numchunks}).


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
    ChunkSrv = lookup_chunk_server(TorrentID),
    case Piecestate of
        invalid -> error(badarg);
        _ -> call(ChunkSrv, {state_members, Piecestate})
    end.

%% @private
-spec num_state_members(torrent_id(), piece_state()) -> pieceset().
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

%%====================================================================

%% @private
init([TorrentID, ChunkSize, FetchedPieces, PieceSizes, InitTorrentPid]) ->
    etorrent_scarcity:await_scarcity_server(TorrentID),
    true = register_chunk_server(TorrentID),
    Pending = etorrent_pending:originhandle(TorrentID),

    NumPieces = length(PieceSizes),
    PiecesValid = etorrent_pieceset:from_list(FetchedPieces, NumPieces),
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
    
    %% Make it possible to inject the pid of the torrent in tests
    TorrentPid = case InitTorrentPid of
        lookup ->
            {TPid, _} = gproc:await({n, l, {torrent, TorrentID, control}}),
            TPid;
        _ when is_pid(InitTorrentPid) ->
            InitTorrentPid
    end,

    PiecesBegun = etorrent_pieceset:from_list([], NumPieces),
    PriorityBegun = init_priority(TorrentID, begun, PiecesBegun),
    PriorityUnass = init_priority(TorrentID, unassigned, PiecesInvalid),

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
        prio_begun=PriorityBegun,
        prio_unassigned=PriorityUnass,
        pending=Pending},
    {ok, InitState}.


handle_call({request_chunks, PeerPid, Peerset, Numchunks}, _, State) ->
    #state{
        torrent_id=TorrentID,
        pieces_valid=Valid,
        pieces_unassigned=Unassigned,
        pieces_begun=Begun,
        pieces_assigned=Assigned,
        chunks_assigned=AssignedChunks,
        prio_unassigned=PrioUnassigned,
        prio_begun=PrioBegun,
        pending=Pending} = State,

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
        none ->
            %% We know that the peer has no pieces in the Unassigned or
            %% Begun states. This leaves us with Assigned, Stored and
            %% Valid pieces. If the peer has any pieces that are not
            %% in the Valid state we are still interested.
            Interesting = etorrent_pieceset:difference(Peerset, Valid),
            case etorrent_pieceset:is_empty(Interesting) of
                false -> assigned;
                true  -> not_interested
            end;
        %% One or more that we are already downloading
        begun ->
            #pieceprio{pieces=BegunPriolist} = PrioBegun,
            etorrent_pieceset:first(BegunPriolist, Optimal);
        %% None that we are not already downloading
        %% but one ore more that we would want to download
        unassigned ->
            #pieceprio{pieces=UnassignedPriolist} = PrioUnassigned,
            etorrent_pieceset:first(UnassignedPriolist, SubOptimal)
    end,

    case PieceIndex of
        not_interested ->
            {reply, {ok, not_interested}, State};
        assigned ->
            {reply, {ok, assigned}, State};
        Index ->
            Chunkset = array:get(Index, AssignedChunks),
            Offsets = etorrent_chunkset:min(Chunkset, Numchunks),
            Chunks = [{Index, Offs, Len} || {Offs, Len} <- Offsets],
            NewChunkset = etorrent_chunkset:delete(Chunks, Chunkset),
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
                    UnassignedUpdated = true,
                    BegunUpdated = true;
                {unassigned, assigned} ->
                    NewUnassigned = etorrent_pieceset:delete(Index, Unassigned),
                    NewBegun = Begun,
                    NewAssigned = etorrent_pieceset:insert(Index, Assigned),
                    UnassignedUpdated = true,
                    BegunUpdated = false;
                {begun, begun} ->
                    NewUnassigned = Unassigned,
                    NewBegun = Begun,
                    NewAssigned = Assigned,
                    UnassignedUpdated = false,
                    BegunUpdated = false;
                {begun, assigned} ->
                    NewUnassigned = Unassigned,
                    NewBegun = etorrent_pieceset:delete(Index, Begun),
                    NewAssigned = etorrent_pieceset:insert(Index, Assigned),
                    UnassignedUpdated = false,
                    BegunUpdated = true
            end,

            %% Only update the piece priority lists if the piece set that
            %% they track was updated in this piece state transition.
            NewPrioUnassigned = case UnassignedUpdated of
                false -> PrioUnassigned;
                true  -> update_priority(TorrentID, PrioUnassigned, NewUnassigned)
            end,
            NewPrioBegun = case BegunUpdated of
                false -> PrioBegun;
                true  -> update_priority(TorrentID, PrioBegun, NewBegun)
            end,

            %% The piece is in the assigned state if this was the last chunk
            NewAssigned = case etorrent_chunkset:size(NewChunkset) of
                0 -> etorrent_pieceset:insert(Index, Assigned);
                _ -> Assigned
            end,
            NewState = State#state{
                pieces_unassigned=NewUnassigned,
                pieces_begun=NewBegun,
                pieces_assigned=NewAssigned,
                chunks_assigned=NewAssignedChunks,
                prio_unassigned=NewPrioUnassigned,
                prio_begun=NewPrioBegun},
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
handle_cast({mark_valid, Index}, State) ->
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
        valid ->
            {reply, {error, valid}, State};
        not_stored ->
            {reply, {error, not_stored}, State};
        stored ->
            NewStored = etorrent_pieceset:delete(Index, Stored),
            NewValid = etorrent_pieceset:insert(Index, Valid),
            NewState = State#state{
                pieces_stored=NewStored,
                pieces_valid=NewValid},
            {reply, ok, NewState}
    end.


%% @private
%% If we receive a notification about a stored chunk there are three
%% possible cases that we must consider in order to handle it correctly.
%% 
%% 1. This process is the assigning process
%% 2. The notifictation comes from a peer has not received the new process
%% 3. The notification comes from the new assigning process
%%
%% Case #1 and #3 are handled the same way. Case #2 must be forwarded
%% to the new assigning process unmodified. If it practially guarantees
%% that the chunk will be fetched twice. In this case we don't bother
%% to handle it because we expect the assigning process to send copies
%% of these notifications to this process.
%%
handle_info({chunk, {stored, Piece, Offset, Length, Peerpid}}, State)
when ?in_endgame(State) and not ?is_assigning(State, Peerpid) ->
    #state{assigning=Assigning} = State,
    ok = etorrent_chunkstate:stored(Piece, Offset, Length, Peerpid, Assigning),
    {noreply, State};

handle_info({chunk, {stored, Index, Offset, Length, _}}, State) ->
    #state{
        torrent_pid=TorrentPid,
        pieces_assigned=Assigned,
        pieces_stored=Stored,
        chunks_stored=ChunksStored} = State,

    %% Update the set of chunks in the piece that has been written to disk.
    Chunks = array:get(Index, ChunksStored),
    NewChunks = etorrent_chunkset:delete(Offset, Length, Chunks),
    NewChunksStored = array:set(Index, NewChunks, ChunksStored),

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
        assigned ->
            ok = etorrent_torrent_ctl:piece_stored(TorrentPid, Index),
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
when ?in_endgame(State) ->
    #state{assigning=Assigning} = State,
    ok = etorrent_chunkstate:dropped(Piece, Offset, Length, Peerpid, Assigning),
    {noreply, State};

handle_info({chunk, {dropped, Piece, Offset, Length, _}}, State) ->
    #state{
        torrent_id=TorrentID,
        pieces_begun=Begun,
        pieces_assigned=Assigned,
        chunks_assigned=AssignedChunks,
        prio_begun=PrioBegun} = State,

     %% Add the chunk back to the chunkset of the piece.
     Chunks = array:get(Piece, AssignedChunks),
     NewChunks = etorrent_chunkset:insert(Offset, Length, Chunks),
     NewAssignedChunks = array:set(Piece, NewChunks, AssignedChunks),

     %% Assigned -> Begun
     NewAssigned = etorrent_pieceset:delete(Piece, Assigned),
     NewBegun = etorrent_pieceset:insert(Piece, Begun),
     NewPrioBegun = update_priority(TorrentID, PrioBegun, NewBegun),
 
     NewState = State#state{
         pieces_begun=NewBegun,
         pieces_assigned=NewAssigned,
         chunks_assigned=NewAssignedChunks,
         prio_begun=NewPrioBegun},
    {noreply, NewState};


handle_info({scarcity, Ref, Tag, Piecelist}, State) ->
    #state{prio_begun=Begun, prio_unassigned=Unass} = State,
    %% Verify that the tag is valid before verifying the reference
    #pieceprio{tag=Beguntag, ref=Begunref} = Begun,
    #pieceprio{tag=Unasstag, ref=Unassref} = Unass,
    case Tag of
        Beguntag -> ok;
        Unasstag -> ok
    end,
    %% Verify that the reference belongs to an active subscription
    NewState = case Ref of
        Begunref ->
            NewBegun = Begun#pieceprio{pieces=Piecelist},
            State#state{prio_begun=NewBegun};
        Unassref ->
            NewUnass = Unass#pieceprio{pieces=Piecelist},
            State#state{prio_unassigned=NewUnass};
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
-define(chunk_server, ?MODULE).
-define(scarcity, etorrent_scarcity).
-define(timer, etorrent_timer).
-define(pending, etorrent_pending).


chunk_server_test_() ->
    {setup,
        fun()  -> application:start(gproc) end,
        fun(_) -> application:stop(gproc) end,
    {foreach, local,
        fun setup_env/0,
        fun teardown_env/1,
    [?_test(lookup_registered_case()),
     ?_test(unregister_case()),
     ?_test(register_two_case()),
     ?_test(not_interested_case()),
     ?_test(not_interested_valid_case()),
     ?_test(request_one_case()),
     ?_test(mark_dropped_case()),
     ?_test(mark_all_dropped_case()),
     ?_test(drop_none_on_exit_case()),
     ?_test(drop_all_on_exit_case()),
     ?_test(marked_stored_not_dropped_case()),
     ?_test(mark_fetched_noop_case()),
     ?_test(mark_valid_not_stored_case()),
     ?_test(mark_valid_stored_case()),
     ?_test(all_stored_marks_stored_case()),
     ?_test(get_all_request_case()),
     ?_test(unassigned_to_assigned_case())
     ]}}.


testid() -> 2.

setup_env() ->
    Valid = [],
    {ok, Time} = ?timer:start_link(queue),
    {ok, SPid} = ?scarcity:start_link(testid(), Time, 8),
    {ok, CPid} = ?chunk_server:start_link(testid(), 1, Valid, [{0, 2}, {1, 2}, {2, 2}], self()),
    true = ?chunk_server:register_peer(testid()),
    {Time, SPid, CPid}.

teardown_env({Time, SPid, CPid}) ->
    ok = etorrent_utils:shutdown(Time),
    ok = etorrent_utils:shutdown(SPid),
    ok = etorrent_utils:shutdown(CPid).

lookup_registered_case() ->
    ?assertEqual(true, ?chunk_server:register_chunk_server(0)),
    ?assertEqual(self(), ?chunk_server:lookup_chunk_server(0)).

unregister_case() ->
    ?assertEqual(true, ?chunk_server:register_chunk_server(1)),
    ?assertEqual(true, ?chunk_server:unregister_chunk_server(1)),
    ?assertError(badarg, ?chunk_server:lookup_chunk_server(1)).

register_two_case() ->
    Main = self(),
    {Pid, Ref} = erlang:spawn_monitor(fun() ->
        etorrent_utils:expect(go),
        true = ?chunk_server:register_chunk_server(20),
        Main ! registered,
        etorrent_utils:expect(die)
    end),
    Pid ! go,
    etorrent_utils:expect(registered),
    ?assertError(badarg, ?chunk_server:register_chunk_server(20)),
    Pid ! die,
    etorrent_utils:wait(Ref).

not_interested_case() ->
    Has = etorrent_pieceset:from_list([], 3),
    Ret = ?chunk_server:request_chunks(testid(), Has, 1),
    ?assertEqual({ok, not_interested}, Ret).

not_interested_valid_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    _   = ?chunk_server:request_chunks(testid(), Has, 2),
    ok  = ?chunk_server:mark_stored(testid(), 0, 0, 1),
    ok  = ?chunk_server:mark_stored(testid(), 0, 1, 1),
    ok  = ?chunk_server:mark_valid(testid(), 0),
    Ret = ?chunk_server:request_chunks(testid(), Has, 2),
    ?assertEqual({ok, not_interested}, Ret).

request_one_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    Ret = ?chunk_server:request_chunks(testid(), Has, 1),
    ?assertEqual({ok, [{0, 0, 1}]}, Ret).

mark_dropped_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(testid(), Has, 1),
    {ok, [{0, 1, 1}]} = ?chunk_server:request_chunks(testid(), Has, 1),
    ok  = ?chunk_server:mark_dropped(testid(), 0, 0, 1),
    Ret = ?chunk_server:request_chunks(testid(), Has, 1),
    ?assertEqual({ok, [{0, 0, 1}]}, Ret).

mark_all_dropped_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunk_server:request_chunks(testid(), Has, 1)),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunk_server:request_chunks(testid(), Has, 1)),
    ok = ?chunk_server:mark_all_dropped(testid()),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunk_server:request_chunks(testid(), Has, 1)),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunk_server:request_chunks(testid(), Has, 1)).

drop_all_on_exit_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() ->
        true = ?chunk_server:register_peer(testid()),
        {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(testid(), Has, 1),
        {ok, [{0, 1, 1}]} = ?chunk_server:request_chunks(testid(), Has, 1)
    end),
    _ = monitor(process, Pid),
    ok  = receive {'DOWN', _, process, Pid, _} -> ok end,
    timer:sleep(100),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunk_server:request_chunks(testid(), Has, 1)),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunk_server:request_chunks(testid(), Has, 1)).

drop_none_on_exit_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() -> true = ?chunk_server:register_peer(testid()) end),
    _ = monitor(process, Pid),
    ok  = receive {'DOWN', _, process, Pid, _} -> ok end,
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunk_server:request_chunks(testid(), Has, 1)),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunk_server:request_chunks(testid(), Has, 1)).

marked_stored_not_dropped_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() ->
        true = ?chunk_server:register_peer(testid()),
        {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(testid(), Has, 1),
        ok = ?chunk_server:mark_stored(testid(), 0, 0, 1)
    end),
    _ = monitor(process, Pid),
    ok  = receive {'DOWN', _, process, Pid, _} -> ok end,
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunk_server:request_chunks(testid(), Has, 1)).

mark_fetched_noop_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() ->
        true = ?chunk_server:register_peer(testid()),
        {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(testid(), Has, 1),
        {ok, true} = ?chunk_server:mark_fetched(testid(), 0, 0, 1)
    end),
    _ = monitor(process, Pid),
    ok  = receive {'DOWN', _, process, Pid, _} -> ok end,
    timer:sleep(1000),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunk_server:request_chunks(testid(), Has, 1)).


mark_valid_not_stored_case() ->
    Ret = ?chunk_server:mark_valid(testid(), 0),
    ?assertEqual({error, not_stored}, Ret).

mark_valid_stored_case() ->
    Has = etorrent_pieceset:from_list([0,1], 3),
    {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(testid(), Has, 1),
    {ok, [{0, 1, 1}]} = ?chunk_server:request_chunks(testid(), Has, 1),
    ok  = ?chunk_server:mark_stored(testid(), 0, 0, 1),
    ok  = ?chunk_server:mark_stored(testid(), 0, 1, 1),
    ?assertEqual(ok, ?chunk_server:mark_valid(testid(), 0)),
    ?assertEqual({error, valid}, ?chunk_server:mark_valid(testid(), 0)).

all_stored_marks_stored_case() ->
    Has = etorrent_pieceset:from_list([0,1], 3),
    {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(testid(), Has, 1),
    {ok, [{0, 1, 1}]} = ?chunk_server:request_chunks(testid(), Has, 1),
    ?assertMatch({ok, [{1, 0, 1}]}, ?chunk_server:request_chunks(testid(), Has, 1)),
    ?assertMatch({ok, [{1, 1, 1}]}, ?chunk_server:request_chunks(testid(), Has, 1)).

get_all_request_case() ->
    Has = etorrent_pieceset:from_list([0,1,2], 3),
    {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(testid(), Has, 1),
    {ok, [{0, 1, 1}]} = ?chunk_server:request_chunks(testid(), Has, 1),
    {ok, [{1, 0, 1}]} = ?chunk_server:request_chunks(testid(), Has, 1),
    {ok, [{1, 1, 1}]} = ?chunk_server:request_chunks(testid(), Has, 1),
    {ok, [{2, 0, 1}]} = ?chunk_server:request_chunks(testid(), Has, 1),
    {ok, [{2, 1, 1}]} = ?chunk_server:request_chunks(testid(), Has, 1),
    ?assertEqual({ok, assigned}, ?chunk_server:request_chunks(testid(), Has, 1)).

unassigned_to_assigned_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    {ok, [{0,0,1}, {0,1,1}]} = ?chunk_server:request_chunks(testid(), Has, 2),
    ?assertEqual({ok, assigned}, ?chunk_server:request_chunks(testid(), Has, 1)).

-endif.
