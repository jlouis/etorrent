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
-module(etorrent_chunk_mgr).
-behaviour(gen_server).

-include("log.hrl").

-include_lib("stdlib/include/ms_transform.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% peer API
-export([start_link/5,
         mark_valid/2,
         mark_fetched/4,
         mark_stored/4,
         mark_dropped/4,
         mark_all_dropped/1,
         request_chunks/3]).

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
-type monitorset() :: etorrent_monitorset:monitorset().
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
    torrent_id      :: pos_integer(),
    torrent_pid     :: pid(),
    chunk_size      :: pos_integer(),
    %% Piece state sets
    pieces_valid      :: pieceset(),
    pieces_unassigned :: pieceset(),
    pieces_begun      :: pieceset(),
    pieces_assigned   :: pieceset(),
    pieces_stored     :: pieceset(),
    %% Chunk sets for pieces
    chunks_assigned :: array(),
    chunks_stored   :: array(),
    %% Chunks assigned to peers
    peer_monitors   :: monitorset(),
    %% Piece priority lists
    prio_begun :: #pieceprio{},
    prio_unassigned :: #pieceprio{}}).

%% # Open requests
%% A gb_tree mapping {PieceIndex, Offset} to Chunklength
%% is kept as the state of each monitored process.
%%
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
-spec mark_valid(torrent_id(), pos_integer()) ->
          ok | {error, not_stored | valid}.
mark_valid(TorrentID, PieceIndex) ->
    ChunkSrv = lookup_chunk_server(TorrentID),
    call(ChunkSrv, {mark_valid, self(), PieceIndex}).


%% @doc
%% Mark a chunk as fetched but not written to file.
%% @end
-spec mark_fetched(torrent_id(), pos_integer(),
                   pos_integer(), pos_integer()) -> {ok, boolean()}.
mark_fetched(TorrentID, Index, Offset, Length) ->
    ChunkSrv = lookup_chunk_server(TorrentID),
    call(ChunkSrv, {mark_fetched, self(), Index, Offset, Length}).

%& @doc
%% Mark a chunk as fetched and written to file.
%% @end
-spec mark_stored(torrent_id(), pos_integer(),
                  pos_integer(), pos_integer()) -> ok.
mark_stored(TorrentID, Index, Offset, Length) ->
    ChunkSrv = lookup_chunk_server(TorrentID),
    call(ChunkSrv, {mark_stored, self(), Index, Offset, Length}).

%& @doc
%% Reinsert a chunk into the request queue.
%% @end
-spec mark_dropped(torrent_id(), pos_integer(),
                  pos_integer(), pos_integer()) -> ok.
mark_dropped(TorrentID, Index, Offset, Length) ->
    ChunkSrv = lookup_chunk_server(TorrentID),
    cast(ChunkSrv, {mark_dropped, self(), Index, Offset, Length}).

%% @doc
%% Mark all currently open requests as dropped.
%% @end
-spec mark_all_dropped(torrent_id()) -> ok.
mark_all_dropped(TorrentID) ->
    ChunkSrv = lookup_chunk_server(TorrentID),
    call(ChunkSrv, {mark_all_dropped, self()}).


%% @doc
%% Request a 
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
        peer_monitors=etorrent_monitorset:new(),
        prio_begun=PriorityBegun,
        prio_unassigned=PriorityUnass},
    {ok, InitState}.


handle_call({register_peer, PeerPid}, _, State) ->
    %% Add a new peer to the set of monitored peers. Set the initial state
    %% of the monitored peer to an empty set open requests so that we don't
    %% need to check for this during the lifetime of the peer.
    #state{peer_monitors=PeerMonitors} = State,
    OpenReqs = gb_trees:empty(),
    NewMonitors = etorrent_monitorset:insert(PeerPid, OpenReqs, PeerMonitors),
    NewState = State#state{peer_monitors=NewMonitors},
    {reply, true, NewState};

handle_call({request_chunks, PeerPid, Peerset, Numchunks}, _, State) ->
    #state{
        torrent_id=TorrentID,
        pieces_valid=Valid,
        pieces_unassigned=Unassigned,
        pieces_begun=Begun,
        pieces_assigned=Assigned,
        chunks_assigned=AssignedChunks,
        peer_monitors=Peers,
        prio_unassigned=PrioUnassigned,
        prio_begun=PrioBegun} = State,

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
            Chunks   = etorrent_chunkset:min(Chunkset, Numchunks),
            NewChunkset = etorrent_chunkset:delete(Chunks, Chunkset),
            NewAssignedChunks = array:set(Index, NewChunkset, AssignedChunks),
            %% Add the chunk to this peer's set of open requests
            OpenReqs = etorrent_monitorset:fetch(PeerPid, Peers),
            NewReqs  = lists:foldl(fun({Offs, Len}, Acc) ->
                gb_trees:insert({Index, Offs}, Len, Acc)
            end, OpenReqs, Chunks),
            NewPeers = etorrent_monitorset:update(PeerPid, NewReqs, Peers),

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


            NewState = State#state{
                pieces_unassigned=NewUnassigned,
                pieces_begun=NewBegun,
                pieces_assigned=NewAssigned,
                chunks_assigned=NewAssignedChunks,
                peer_monitors=NewPeers,
                prio_unassigned=NewPrioUnassigned,
                prio_begun=NewPrioBegun},
            ReturnValue = [{Index, Offs, Len} || {Offs, Len} <- Chunks],
            {reply, {ok, ReturnValue}, NewState}
    end;

handle_call({mark_valid, _, Index}, _, State) ->
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
    end;

handle_call({mark_fetched, _Pid, _Index, _Offset, _Length}, _, State) ->
    %% If we are in endgame mode, requests for a chunk may have been
    %% sent to more than one peer. Return a boolean indicating if the
    %% peer was the first one to mark this chunk as fetched.
    {reply, {ok, true}, State};

handle_call({mark_stored, Pid, Index, Offset, Length}, _, State) ->
    %% The calling process has written this chunk to disk.
    %% Remove it from the list of open requests of the peer.
    #state{
        torrent_pid=TorrentPid,
        pieces_assigned=Assigned,
        pieces_stored=Stored,
        peer_monitors=Peers,
        chunks_stored=ChunksStored} = State,
    OpenReqs = etorrent_monitorset:fetch(Pid, Peers),
    NewReqs  = gb_trees:delete({Index, Offset}, OpenReqs),
    NewPeers = etorrent_monitorset:update(Pid, NewReqs, Peers),
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
            IState = State#state{
                chunks_stored=NewChunksStored,
                peer_monitors=NewPeers},
            IState;
        %% Assigned -> Assigned
        assigned when not Wasstored ->
            IState = State#state{
                chunks_stored=NewChunksStored,
                peer_monitors=NewPeers},
            IState;
        %% Assigned -> Stored
        assigned ->
            ok = etorrent_torrent_ctl:piece_stored(TorrentPid, Index),
            NewAssigned = etorrent_pieceset:delete(Index, Assigned),
            NewStored = etorrent_pieceset:insert(Index, Stored),
            IState = State#state{
                chunks_stored=NewChunksStored,
                peer_monitors=NewPeers,
                pieces_assigned=NewAssigned,
                pieces_stored=NewStored},
            IState
    end,
    {reply, ok, NewState};

handle_call({mark_all_dropped, Pid}, _, State) ->
    %% When marking all requests as dropped, send a series of
    %% mark_dropped-messages to ourselves. The state of each
    %% piece should be restored eventually.
    #state{peer_monitors=Peers} = State,

    %% Add the chunks back to the chunkset of each piece.
    OpenReqs = etorrent_monitorset:fetch(Pid, Peers),
    _ = [begin
        cast(self(), {mark_dropped, Pid, Index, Offset, Length})
    end || {Index, Offset, Length} <- chunk_list(OpenReqs)],
    {reply, ok, State};

handle_call({state_members, Piecestate}, _, State) ->
    Stateset = case Piecestate of
        unassigned -> State#state.pieces_unassigned;
        begun -> State#state.pieces_begun;
        assigned -> State#state.pieces_assigned;
        stored -> State#state.pieces_stored;
        valid -> State#state.pieces_valid
    end,
    {reply, Stateset, State}.

handle_cast({mark_dropped, Pid, Index, Offset, Length}, State) ->
    #state{
        torrent_id=TorrentID,
        pieces_begun=Begun,
        pieces_assigned=Assigned,
        chunks_assigned=AssignedChunks,
        peer_monitors=Peers,
        prio_begun=PrioBegun} = State,

     %% Reemove the chunk from the peer's set of open requests
     OpenReqs = etorrent_monitorset:fetch(Pid, Peers),
     NewReqs  = gb_trees:delete({Index, Offset}, OpenReqs),
     NewPeers = etorrent_monitorset:update(Pid, NewReqs, Peers),
 
     %% Add the chunk back to the chunkset of the piece.
     Chunks = array:get(Index, AssignedChunks),
     NewChunks = etorrent_chunkset:insert(Offset, Length, Chunks),
     NewAssignedChunks = array:set(Index, NewChunks, AssignedChunks),

     %% Assigned -> Begun
     NewAssigned = etorrent_pieceset:delete(Index, Assigned),
     NewBegun = etorrent_pieceset:insert(Index, Begun),
     NewPrioBegun = update_priority(TorrentID, PrioBegun, NewBegun),
 
     NewState = State#state{
         pieces_begun=NewBegun,
         pieces_assigned=NewAssigned,
         chunks_assigned=NewAssignedChunks,
         peer_monitors=NewPeers,
         prio_begun=NewPrioBegun},
    {noreply, NewState};

handle_cast({demonitor, Pid}, State) ->
    %% This message should be received after all mark_dropped messages.
    %% At this point the set of open requests for the peer should be empty.
    #state{peer_monitors=Peers} = State,
    NewPeers = etorrent_monitorset:delete(Pid, Peers),
    NewState = State#state{peer_monitors=NewPeers},
    {noreply, NewState}.

handle_info({'DOWN', _, process, Pid, _}, State) ->
    %% When a peer crashes, send a series of mark-dropped messages
    %% and a demonitor-message to ourselves.
    #state{peer_monitors=Peers} = State,
    OpenReqs = etorrent_monitorset:fetch(Pid, Peers),
    _ = [begin
        cast(self(), {mark_dropped, Pid, Index, Offset, Length})
    end || {Index, Offset, Length} <- chunk_list(OpenReqs)],
    _ = cast(self(), {demonitor, Pid}),
    {noreply, State};

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

%%
%% Given a tree of a peers currently open requests, return a list of
%% tuples containing the piece index, offset and length of each request.
%%
-spec chunk_list(gb_tree()) -> [{pos_integer(), pos_integer(), pos_integer()}].
chunk_list(OpenReqs) ->
    [{I,O,L} || {{I,O},L} <- gb_trees:to_list(OpenReqs)].


-ifdef(TEST).
-define(chunk_server, ?MODULE).
-define(scarcity, etorrent_scarcity).
-define(timer, etorrent_timer).


chunk_server_test_() ->
    {setup,
        fun()  -> application:start(gproc) end,
        fun(_) -> application:stop(gproc) end,
        [?_test(lookup_registered_case()),
         ?_test(unregister_case()),
         ?_test(register_two_case()),
         ?_test(not_interested_case(test_env(2, []))),
         ?_test(not_interested_valid_case(test_env(3, [0]))),
         ?_test(request_one_case(test_env(4, []))),
         ?_test(mark_dropped_case(test_env(5, []))),
         ?_test(mark_all_dropped_case(test_env(6, []))),
         ?_test(drop_none_on_exit_case(test_env(7, []))),
         ?_test(drop_all_on_exit_case(test_env(8, []))),
         ?_test(marked_stored_not_dropped_case(test_env(9, []))),
         ?_test(mark_fetched_noop_case(test_env(10, []))),
         ?_test(mark_valid_not_stored_case(test_env(11, []))),
         ?_test(mark_valid_stored_case(test_env(12, []))),
         ?_test(all_stored_marks_stored_case(test_env(13, []))),
         ?_test(get_all_request_case(test_env(14, []))),
         ?_test(unassigned_to_assigned_case(test_env(15, [])))
        ]}.

test_env(N, Valid) ->
    {ok, Time} = ?timer:start_link(queue),
    {ok, SPid} = ?scarcity:start_link(N, Time, 8),
    {ok, CPid}  = ?chunk_server:start_link(N, 1, Valid, [{0, 2}, {1, 2}, {2, 2}], self()),
    true = ?chunk_server:register_peer(N),
    {N, Time, SPid, CPid}.

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

not_interested_case({N, Time, SPid, CPid}) ->
    Has = etorrent_pieceset:from_list([], 3),
    Ret = ?chunk_server:request_chunks(N, Has, 1),
    ?assertEqual({ok, not_interested}, Ret).

not_interested_valid_case({N, Time, SPid, CPid}) ->
    Has = etorrent_pieceset:from_list([0], 3),
    Ret = ?chunk_server:request_chunks(N, Has, 1),
    ?assertEqual({error, not_interested}, Ret).

request_one_case({N, Time, SPid, CPid}) ->
    Has = etorrent_pieceset:from_list([0], 3),
    Ret = ?chunk_server:request_chunks(N, Has, 1),
    ?assertEqual({ok, [{0, 0, 1}]}, Ret).

mark_dropped_case({N, Time, SPid, CPid}) ->
    Has = etorrent_pieceset:from_list([0], 3),
    {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(N, Has, 1),
    {ok, [{0, 1, 1}]} = ?chunk_server:request_chunks(N, Has, 1),
    ok  = ?chunk_server:mark_dropped(N, 0, 0, 1),
    Ret = ?chunk_server:request_chunks(N, Has, 1),
    ?assertEqual({ok, [{0, 0, 1}]}, Ret).

mark_all_dropped_case({N, Time, SPid, CPid}) ->
    Has = etorrent_pieceset:from_list([0], 3),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunk_server:request_chunks(N, Has, 1)),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunk_server:request_chunks(N, Has, 1)),
    ok = ?chunk_server:mark_all_dropped(N),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunk_server:request_chunks(N, Has, 1)),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunk_server:request_chunks(N, Has, 1)).

drop_all_on_exit_case({N, Time, SPid, CPid}) ->
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() ->
        true = ?chunk_server:register_peer(N),
        {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(N, Has, 1),
        {ok, [{0, 1, 1}]} = ?chunk_server:request_chunks(N, Has, 1)
    end),
    _ = monitor(process, Pid),
    ok  = receive {'DOWN', _, process, Pid, _} -> ok end,
    timer:sleep(100),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunk_server:request_chunks(N, Has, 1)),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunk_server:request_chunks(N, Has, 1)).

drop_none_on_exit_case({N, Time, SPid, CPid}) ->
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() -> true = ?chunk_server:register_peer(N) end),
    _ = monitor(process, Pid),
    ok  = receive {'DOWN', _, process, Pid, _} -> ok end,
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunk_server:request_chunks(N, Has, 1)),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunk_server:request_chunks(N, Has, 1)).

marked_stored_not_dropped_case({N, Time, SPid, CPid}) ->
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() ->
        true = ?chunk_server:register_peer(N),
        {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(N, Has, 1),
        ok = ?chunk_server:mark_stored(N, 0, 0, 1)
    end),
    _ = monitor(process, Pid),
    ok  = receive {'DOWN', _, process, Pid, _} -> ok end,
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunk_server:request_chunks(N, Has, 1)).

mark_fetched_noop_case({N, Time, SPid, CPid}) ->
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() ->
        true = ?chunk_server:register_peer(N),
        {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(N, Has, 1),
        {ok, []} = ?chunk_server:mark_fetched(N, 0, 0, 1)
    end),
    _ = monitor(process, Pid),
    ok  = receive {'DOWN', _, process, Pid, _} -> ok end,
    timer:sleep(10),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunk_server:request_chunks(N, Has, 1)).


mark_valid_not_stored_case({N, Time, SPid, CPid}) ->
    Ret = ?chunk_server:mark_valid(N, 0),
    ?assertEqual({error, not_stored}, Ret).

mark_valid_stored_case({N, Time, SPid, CPid}) ->
    Has = etorrent_pieceset:from_list([0,1], 3),
    {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(N, Has, 1),
    {ok, [{0, 1, 1}]} = ?chunk_server:request_chunks(N, Has, 1),
    ok  = ?chunk_server:mark_stored(N, 0, 0, 1),
    ok  = ?chunk_server:mark_stored(N, 0, 1, 1),
    ?assertEqual(ok, ?chunk_server:mark_valid(N, 0)),
    ?assertEqual({error, valid}, ?chunk_server:mark_valid(N, 0)).

all_stored_marks_stored_case({N, Time, SPid, CPid}) ->
    Has = etorrent_pieceset:from_list([0,1], 3),
    {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(N, Has, 1),
    {ok, [{0, 1, 1}]} = ?chunk_server:request_chunks(N, Has, 1),
    ?assertMatch({ok, [{1, 0, 1}]}, ?chunk_server:request_chunks(N, Has, 1)),
    ?assertMatch({ok, [{1, 1, 1}]}, ?chunk_server:request_chunks(N, Has, 1)).

get_all_request_case({N, Time, SPid, CPid}) ->
    Has = etorrent_pieceset:from_list([0,1,2], 3),
    {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(N, Has, 1),
    {ok, [{0, 1, 1}]} = ?chunk_server:request_chunks(N, Has, 1),
    {ok, [{1, 0, 1}]} = ?chunk_server:request_chunks(N, Has, 1),
    {ok, [{1, 1, 1}]} = ?chunk_server:request_chunks(N, Has, 1),
    {ok, [{2, 0, 1}]} = ?chunk_server:request_chunks(N, Has, 1),
    {ok, [{2, 1, 1}]} = ?chunk_server:request_chunks(N, Has, 1),
    ?assertEqual({error, assigned}, ?chunk_server:request_chunks(N, Has, 1)).

unassigned_to_assigned_case({N, Time, SPid, CPid}) ->
    Has = etorrent_pieceset:from_list([0], 3),
    {ok, [{0,0,1}, {0,1,1}]} = ?chunk_server:request_chunks(N, Has, 2),
    ?assertEqual({error, assigned}, ?chunk_server:request_chunks(N, Has, 1)).

-endif.

