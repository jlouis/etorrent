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

%% @todo: What pid is the chunk recording pid? Control or SendPid?
%% API
-export([start_link/5,
         mark_valid/2,
         mark_fetched/4,
         mark_stored/4,
         mark_dropped/4,
         mark_all_dropped/1,
         request_chunks/3]).

%% gproc registry entries
-export([register_chunk_server/1,
         unregister_chunk_server/1,
         lookup_chunk_server/1,
         register_peer/1]).


%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-import(gen_server, [call/2, cast/2]).
-compile({no_auto_import,[monitor/2]}).
-import(erlang, [monitor/2]).

-type pieceset()   :: etorrent_pieceset:pieceset().
-type monitorset() :: etorrent_monitorset:monitorset().
-type torrent_id() :: etorrent_types:torrent_id().
-type chunk_len() :: etorrent_types:chunk_len().
-type chunk_offset() :: etorrent_types:chunk_offset().
-type piece_index() :: etorrent_types:piece_index().

-record(state, {
    torrent_id      :: pos_integer(),
    torrent_pid     :: pid(),
    chunk_size      :: pos_integer(),
    %% Piece state sets
    pieces_valid    :: pieceset(),
    pieces_begun    :: pieceset(),
    pieces_assigned :: pieceset(),
    pieces_stored   :: pieceset(),
    %% Chunk sets for pieces
    chunks_assigned :: array(),
    chunks_stored   :: array(),
    %% Chunks assigned to peers
    peer_monitors   :: monitorset()}).

%% # Open requests
%% A gb_tree mapping {PieceIndex, Offset} to Chunklength
%% is kept as the state of each monitored process.
%%
%% # Piece states
%% As the download of a torrent progresses, and regresses, each piece
%% enters and leaves a sequence of states.
%% 
%% ## Sequence
%% 1. Invalid
%% 2. Begun
%% 3. Assigned
%% 4. Stored
%% 5. Valid
%% 
%% ## Invalid
%% By default all pieces are considered as invalid. A piece
%% is invalid if it is not a member of the set of valid pieces
%%
%% ## Begun
%% When the download of a piece has begun the piece enters
%% the begun state. While the piece is in this state it is
%% still considered valid, but it enables the chunk server
%% prioritize these pieces.
%% A piece never leaves the begun state.
%%
%% ## Assigned
%% When all chunks of the piece has been assigned to be downloaded
%% from a set of peers, when the chunk set of the piece is empty,
%% the piece enters the assigned state. If a piece has entered the
%% assigned state it is considered begun.
%% A piece leaves the assigned state if it has not yet entered the
%% stored if a request has been dropped.
%%
%% ## Stored
%% When all chunks of a piece has been marked as stored the piece
%% enters the stored state. A piece is in the stored state until
%% it has been validated.
%% A piece must not leave the stored state.
%%
%% ## Valid
%% A piece enters the valid state when it has been marked as valid.
%% A piece may noy leave the valid state.
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

-spec register_peer(torrent_id()) -> true.
register_peer(TorrentID) ->
    ChunkSrv = lookup_chunk_server(TorrentID),
    gen_server:call(ChunkSrv, {register_peer, self()}).

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


%%====================================================================

%% @private
init([TorrentID, ChunkSize, FetchedPieces, PieceSizes, InitTorrentPid]) ->
    true = register_chunk_server(TorrentID),

    NumPieces = length(PieceSizes),
    PiecesValid   = etorrent_pieceset:from_list(FetchedPieces, NumPieces),

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

    InitState = #state{
        torrent_id=TorrentID,
        torrent_pid=TorrentPid,
        chunk_size=ChunkSize,
        pieces_valid=PiecesValid,
        %% All valid pieces are also begun, assigned and stored
        pieces_begun=PiecesValid,
        pieces_assigned=PiecesValid,
        pieces_stored=PiecesValid,
        %% Initially, the sets of assigned and stored chunks are equal
        chunks_assigned=ChunkSets,
        chunks_stored=ChunkSets,
        peer_monitors=etorrent_monitorset:new()},
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
        pieces_begun=Begun,
        pieces_assigned=Assigned,
        pieces_stored=Stored,
        chunks_assigned=AssignedChunks,
        peer_monitors=Peers} = State,

    %% Consider pieces that has an empty chunkset 
    
    %% If this peer has no pieces that we are already downloading, begin
    %% downloading a new piece if this peer has any interesting pieces.
    Optimal = etorrent_pieceset:intersection(Peerset,
              etorrent_pieceset:difference(Begun, Assigned)),
    SubOptimal = etorrent_pieceset:difference(Peerset, Assigned),
    HasOptimal = not etorrent_pieceset:is_empty(Optimal),
    HasSubOptimal = not etorrent_pieceset:is_empty(SubOptimal),

    PieceIndex = case {HasOptimal, HasSubOptimal} of
        %% None that we are not already downloading
        %% and none that we would want to download
        {false, false} ->
            Interesting = etorrent_pieceset:difference(Peerset, Stored),
            case etorrent_pieceset:is_empty(Interesting) of
                true  -> not_interested;
                false -> assigned
            end;
        %% None that we are not already downloading
        %% but one ore more that we would want to download
        {false, _} ->
            etorrent_pieceset:min(SubOptimal);
        %% One or more that we are already downloading
        {_, _} ->
            etorrent_pieceset:min(Optimal)
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
            NewBegun = etorrent_pieceset:insert(Index, Begun),
            %% Add the chunk to this peer's set of open requests
            OpenReqs = etorrent_monitorset:fetch(PeerPid, Peers),
            NewReqs  = lists:foldl(fun({Offs, Len}, Acc) ->
                gb_trees:insert({Index, Offs}, Len, Acc)
            end, OpenReqs, Chunks),
            NewPeers = etorrent_monitorset:update(PeerPid, NewReqs, Peers),
            %% The piece is in the assigned state if this was the last chunk
            NewAssigned = case etorrent_chunkset:size(NewChunkset) of
                0 -> etorrent_pieceset:insert(Index, Assigned);
                _ -> Assigned
            end,

            NewState = State#state{
                pieces_begun=NewBegun,
                pieces_assigned=NewAssigned,
                chunks_assigned=NewAssignedChunks,
                peer_monitors=NewPeers},
            ReturnValue = [{Index, Offs, Len} || {Offs, Len} <- Chunks],
            {reply, {ok, ReturnValue}, NewState}
    end;

handle_call({mark_valid, _, Index}, _, State) ->
    %% Mark a piece as valid if all chunks of the
    %% piece has been marked as stored.
    #state{
        pieces_valid=Valid,
        chunks_assigned=PieceChunks} = State,
    IsValid = etorrent_pieceset:is_member(Index, Valid),
    Chunks = array:get(Index, PieceChunks),
    BytesLeft = etorrent_chunkset:size(Chunks),
    case {IsValid, BytesLeft} of
        {true, _} ->
            {reply, {error, valid}, State};
        {false, 0} ->
            NewValid = etorrent_pieceset:insert(Index, Valid),
            NewState = State#state{pieces_valid=NewValid},
            {reply, ok, NewState};
        {false, _} ->
            {reply, {error, not_stored}, State}
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
    %% Check if all chunks in this piece has been written to disk now.
    NewStored = case etorrent_chunkset:size(NewChunks) of
        0 ->
            ok = etorrent_torrent_ctl:piece_stored(TorrentPid, Index),
            etorrent_pieceset:insert(Index, Stored);
        _ ->
            Stored
    end,
    NewState = State#state{
        pieces_stored=NewStored,
        chunks_stored=NewChunksStored,
        peer_monitors=NewPeers},
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
    {reply, ok, State}.

handle_cast({mark_dropped, Pid, Index, Offset, Length}, State) ->
    #state{
        pieces_assigned=Assigned,
        chunks_assigned=AssignedChunks,
        peer_monitors=Peers} = State,
     %% Reemove the chunk from the peer's set of open requests
     OpenReqs = etorrent_monitorset:fetch(Pid, Peers),
     NewReqs  = gb_trees:delete({Index, Offset}, OpenReqs),
     NewPeers = etorrent_monitorset:update(Pid, NewReqs, Peers),
 
     %% Add the chunk back to the chunkset of the piece.
     Chunks = array:get(Index, AssignedChunks),
     NewChunks = etorrent_chunkset:insert(Offset, Length, Chunks),
     NewAssignedChunks = array:set(Index, NewChunks, AssignedChunks),

     %% This piece is no longer in the assigned state
     NewAssigned = etorrent_pieceset:delete(Index, Assigned),
 
     NewState = State#state{
         pieces_assigned=NewAssigned,
         chunks_assigned=NewAssignedChunks,
         peer_monitors=NewPeers},
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
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%
%% Given a tree of a peers currently open requests, return a list of
%% tuples containing the piece index, offset and length of each request.
%%
-spec chunk_list(gb_tree()) -> [{pos_integer(), pos_integer(), pos_integer()}].
chunk_list(OpenReqs) ->
    [{I,O,L} || {{I,O},L} <- gb_trees:to_list(OpenReqs)].


-ifdef(TEST).
-define(chunk_server, ?MODULE).


initial_chunk_server(ID) ->
    {ok, Pid} = ?chunk_server:start_link(ID, 1, [], [{0, 2}, {1, 2}, {2, 2}], self()),
    true = ?chunk_server:register_peer(ID),
    Pid.

chunk_server_test_() ->
    {setup,
        fun()  -> application:start(gproc) end,
        fun(_) -> application:stop(gproc) end,
        [?_test(lookup_registered_case()),
         ?_test(unregister_case()),
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
         ?_test(get_all_request_case())
        ]}.

lookup_registered_case() ->
    ?assertEqual(true, ?chunk_server:register_chunk_server(0)),
    ?assertEqual(self(), ?chunk_server:lookup_chunk_server(0)).

unregister_case() ->
    ?assertEqual(true, ?chunk_server:register_chunk_server(3)),
    ?assertEqual(true, ?chunk_server:unregister_chunk_server(3)),
    ?assertError(badarg, ?chunk_server:lookup_chunk_server(3)).

not_interested_case() ->
    _ = initial_chunk_server(1),
    Has = etorrent_pieceset:from_list([], 3),
    Ret = ?chunk_server:request_chunks(1, Has, 1),
    ?assertEqual({ok, not_interested}, Ret).

not_interested_valid_case() ->
    ID = 9,
    {ok, _} = ?chunk_server:start_link(ID, 1, [0], [{0, 2}, {1, 2}, {2, 2}], self()),
    true = ?chunk_server:register_peer(ID),
    Has = etorrent_pieceset:from_list([0], 3),
    Ret = ?chunk_server:request_chunks(ID, Has, 1),
    ?assertEqual({ok, not_interested}, Ret).

request_one_case() ->
    _ = initial_chunk_server(2),
    Has = etorrent_pieceset:from_list([0], 3),
    Ret = ?chunk_server:request_chunks(1, Has, 1),
    ?assertEqual({ok, [{0, 0, 1}]}, Ret).

mark_dropped_case() ->
    _ = initial_chunk_server(4),
    Has = etorrent_pieceset:from_list([0], 3),
    {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(4, Has, 1),
    {ok, [{0, 1, 1}]} = ?chunk_server:request_chunks(4, Has, 1),
    ok  = ?chunk_server:mark_dropped(4, 0, 0, 1),
    Ret = ?chunk_server:request_chunks(4, Has, 1),
    ?assertEqual({ok, [{0, 0, 1}]}, Ret).

mark_all_dropped_case() ->
    _ = initial_chunk_server(5),
    Has = etorrent_pieceset:from_list([0], 3),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunk_server:request_chunks(5, Has, 1)),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunk_server:request_chunks(5, Has, 1)),
    ok = ?chunk_server:mark_all_dropped(5),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunk_server:request_chunks(5, Has, 1)),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunk_server:request_chunks(5, Has, 1)).

drop_all_on_exit_case() ->
    _ = initial_chunk_server(6),
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() ->
        true = ?chunk_server:register_peer(6),
        {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(6, Has, 1),
        {ok, [{0, 1, 1}]} = ?chunk_server:request_chunks(6, Has, 1)
    end),
    _ = monitor(process, Pid),
    ok  = receive {'DOWN', _, process, Pid, _} -> ok end,
    timer:sleep(10),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunk_server:request_chunks(6, Has, 1)),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunk_server:request_chunks(6, Has, 1)).

drop_none_on_exit_case() ->
    _ = initial_chunk_server(7),
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() -> true = ?chunk_server:register_peer(7) end),
    _ = monitor(process, Pid),
    ok  = receive {'DOWN', _, process, Pid, _} -> ok end,
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunk_server:request_chunks(7, Has, 1)),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunk_server:request_chunks(7, Has, 1)).

marked_stored_not_dropped_case() ->
    _ = initial_chunk_server(8),
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() ->
        true = ?chunk_server:register_peer(8),
        {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(8, Has, 1),
        ok = ?chunk_server:mark_stored(8, 0, 0, 1)
    end),
    _ = monitor(process, Pid),
    ok  = receive {'DOWN', _, process, Pid, _} -> ok end,
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunk_server:request_chunks(8, Has, 1)).

mark_fetched_noop_case() ->
    _ = initial_chunk_server(10),
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() ->
        true = ?chunk_server:register_peer(10),
        {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(10, Has, 1),
        {ok, true} = ?chunk_server:mark_fetched(10, 0, 0, 1)
    end),
    _ = monitor(process, Pid),
    ok  = receive {'DOWN', _, process, Pid, _} -> ok end,
    timer:sleep(10),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunk_server:request_chunks(10, Has, 1)).


mark_valid_not_stored_case() ->
    _ = initial_chunk_server(11),
    Ret = ?chunk_server:mark_valid(11, 0),
    ?assertEqual({error, not_stored}, Ret).

mark_valid_stored_case() ->
    _ = initial_chunk_server(12),
    Has = etorrent_pieceset:from_list([0,1], 3),
    {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(12, Has, 1),
    {ok, [{0, 1, 1}]} = ?chunk_server:request_chunks(12, Has, 1),
    ok  = ?chunk_server:mark_stored(12, 0, 0, 1),
    ok  = ?chunk_server:mark_stored(12, 0, 1, 1),
    ?assertEqual(ok, ?chunk_server:mark_valid(12, 0)),
    ?assertEqual({error, valid}, ?chunk_server:mark_valid(12, 0)).

all_stored_marks_stored_case() ->
    _ = initial_chunk_server(13),
    Has = etorrent_pieceset:from_list([0,1], 3),
    {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(13, Has, 1),
    {ok, [{0, 1, 1}]} = ?chunk_server:request_chunks(13, Has, 1),
    ?assertMatch({ok, [{1, 0, 1}]}, ?chunk_server:request_chunks(13, Has, 1)),
    ?assertMatch({ok, [{1, 1, 1}]}, ?chunk_server:request_chunks(13, Has, 1)).

get_all_request_case() ->
    _ = initial_chunk_server(14),
    Has = etorrent_pieceset:from_list([0,1,2], 3),
    {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(14, Has, 1),
    {ok, [{0, 1, 1}]} = ?chunk_server:request_chunks(14, Has, 1),
    {ok, [{1, 0, 1}]} = ?chunk_server:request_chunks(14, Has, 1),
    {ok, [{1, 1, 1}]} = ?chunk_server:request_chunks(14, Has, 1),
    {ok, [{2, 0, 1}]} = ?chunk_server:request_chunks(14, Has, 1),
    {ok, [{2, 1, 1}]} = ?chunk_server:request_chunks(14, Has, 1),
    ?assertEqual({ok, assigned}, ?chunk_server:request_chunks(14, Has, 1)).

-endif.

