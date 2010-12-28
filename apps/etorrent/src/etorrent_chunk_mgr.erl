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

-include("types.hrl").
-include("log.hrl").

-include_lib("stdlib/include/ms_transform.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% @todo: What pid is the chunk recording pid? Control or SendPid?
%% API
-export([start_link/4,
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

-import(gen_server, [call/2]).

-type chunkset()   :: etorrent_chunkset:chunkset().
-type pieceset()   :: etorrent_pieceset:pieceset().
-type monitorset() :: etorrent_monitorset:monitorset().

-record(state, {
    torrent_id     :: pos_integer(),
    chunk_size     :: pos_integer(),
    pieces_valid   :: pieceset(),
    pieces_unknown :: pieceset(),
    pieces_chunked :: pieceset(),
    piece_chunks   :: array(),
    peer_monitors  :: monitorset()}).

%% A gb_tree mapping {PieceIndex, Offset} to Chunklength
%% is kept as the state of each monitored process.


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
start_link(TorrentID, ChunkSize, Fetched, Sizes) ->
    gen_server:start_link(?MODULE, [TorrentID, ChunkSize, Fetched, Sizes], []).

%% @doc
%% Mark a piece as completly stored to disk and validated.
%% @end
-spec mark_valid(torrent_id(), pos_integer()) -> ok | {error, not_stored}.
mark_valid(TorrentID, PieceIndex) ->
    ChunkSrv = lookup_chunk_server(TorrentID),
    call(ChunkSrv, {mark_valid, self(), PieceIndex}).


%% @doc
%% Mark a chunk as fetched but not written to file.
%% @end
-spec mark_fetched(torrent_id(), pos_integer(),
                   pos_integer(), pos_integer()) -> {ok, list(pid())}.
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
    call(ChunkSrv, {mark_dropped, self(), Index, Offset, Length}).

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
    {ok, list({piece_index(), chunk_offset(), chunk_len()})}.
request_chunks(TorrentID, Pieceset, Numchunks) ->
    ChunkSrv = lookup_chunk_server(TorrentID),
    call(ChunkSrv, {request_chunks, self(), Pieceset, Numchunks}).


%%====================================================================

%% @private
init([TorrentID, ChunkSize, FetchedPieces, PieceSizes]) ->
    true = register_chunk_server(TorrentID),

    NumPieces = length(PieceSizes),
    PiecesValid   = etorrent_pieceset:from_list(FetchedPieces, NumPieces),
    PiecesChunked = etorrent_pieceset:new(NumPieces),

    %% Initialize a full chunkset for all pieces that are left to download
    %% but don't mark them as chunked before a chunk has been deleted from
    %% any of the chunksets.
    AllIndexes = lists:seq(0, NumPieces - 1),
    AllPieces = etorrent_pieceset:from_list(AllIndexes, NumPieces),
    PiecesInvalid = etorrent_pieceset:difference(AllPieces, PiecesValid),
    ChunkList = [begin
        Size = orddict:fetch(N, PieceSizes),
        Set  = etorrent_chunkset:new(Size, ChunkSize),
        {N, Set}
    end || N <- etorrent_pieceset:to_list(PiecesInvalid)],

    %% Initialize an empty chunkset for all pieces that are valid.
    CompletedList = [begin
        Size = orddict:fetch(N, PieceSizes),
        Set  = etorrent_chunkset:from_list(Size, ChunkSize, []),
        {N, Set}
    end || N <- etorrent_pieceset:to_list(PiecesValid)],

    AllChunksets = lists:sort(CompletedList ++ ChunkList),
    PieceChunks  = array:from_orddict(AllChunksets),

    InitState = #state{
        torrent_id=TorrentID,
        chunk_size=ChunkSize,
        pieces_valid=PiecesValid,
        pieces_chunked=PiecesChunked,
        piece_chunks=PieceChunks,
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
        pieces_valid=PiecesValid,
        pieces_chunked=PiecesChunked,
        piece_chunks=PieceChunks,
        peer_monitors=Peers} = State,
    
    %% If this peer has no pieces that we are already downloading, begin
    %% downloading a new piece if this peer has any interesting pieces.
    OptimalPieces    = etorrent_pieceset:intersection(Peerset, PiecesChunked),
    SubOptimalPieces = etorrent_pieceset:difference(Peerset, PiecesValid),
    NumOptimal    = etorrent_pieceset:size(OptimalPieces),
    NumSubOptimal = etorrent_pieceset:size(SubOptimalPieces),

    ?debugVal({NumOptimal, NumSubOptimal}),
    PieceIndex = case {NumOptimal, NumSubOptimal} of
        %% None that we are not already downloading
        %% and none that we would want to download
        {0, 0} ->
            none;
        %% None that we are not already downloading
        %% but one ore more that we would want to download
        {0, N} ->
            etorrent_pieceset:min(SubOptimalPieces);
        %% One or more that we are already downloading
        {N, _} ->
            etorrent_pieceset:min(OptimalPieces)
    end,

    case PieceIndex of
        none ->
            {reply, {error, not_interested}, State};
        PieceIndex ->
            Chunkset    = array:get(PieceIndex, PieceChunks),
            {Offs, Len} = etorrent_chunkset:min(Chunkset),
            ?debugVal([Offs, Len, Chunkset]),
            NewChunkset = etorrent_chunkset:delete(Offs, Len, Chunkset),
            NewChunks   = array:set(PieceIndex, NewChunkset, PieceChunks),
            NewChunked  = etorrent_pieceset:insert(PieceIndex, PiecesChunked),
            %% Add the chunk to this peer's set of open requests
            OpenReqs = etorrent_monitorset:fetch(PeerPid, Peers),
            NewReqs  = gb_trees:insert({PieceIndex, Offs}, Len, OpenReqs),
            NewPeers = etorrent_monitorset:update(PeerPid, NewReqs, Peers),

            NewState = State#state{
                pieces_chunked=NewChunked,
                piece_chunks=NewChunks,
                peer_monitors=NewPeers},
            {reply, {ok, [{PieceIndex, Offs, Len}]}, NewState}
    end;

handle_call({mark_valid, Pid, Index}, _, State) ->
    %% Mark a piece as valid if all chunks of the
    %% piece has been marked as stored.
    #state{
        pieces_valid=Valid,
        piece_chunks=PieceChunks} = State,
    Chunks   = array:get(Index, PieceChunks),
    case etorrent_chunkset:size(Chunks) of
        0 ->
            NewValid = etorrent_pieceset:insert(Index, Valid),
            NewState = State#state{pieces_valid=NewValid},
            {reply, ok, NewState};
        _ ->
            {reply, {error, not_stored}, State}
    end;

handle_call({mark_fetched, Pid, PieceIndex, Offset, Length}, _, State) ->
    %% If we are in endgame mode, requests for a chunk may have been
    %% sent to more than one peer. Return a list of other peers that
    %% a request for this chunk has been sent to so that the caller
    %% can send a cancel-message to all of them.
    {reply, ok, State};

handle_call({mark_stored, Pid, PieceIndex, Offset, Length}, _, State) ->
    %% The calling process has written this chunk to disk.
    %% Remove it from the list of open requests of the process.
    #state{peer_monitors=Peers} = State,
    OpenReqs = etorrent_monitorset:fetch(Pid, Peers),
    NewReqs  = gb_trees:delete({PieceIndex, Offset}, OpenReqs),
    NewPeers = etorrent_monitorset:update(Pid, NewReqs, Peers),
    NewState = State#state{peer_monitors=NewPeers},
    {reply, ok, NewState};

handle_call({mark_dropped, Pid, PieceIndex, Offset, Length}, _, State) ->
    #state{
        piece_chunks=PieceChunks,
        peer_monitors=Peers} = State,
     %% Reemove the chunk from the peer's set of open requests
     OpenReqs = etorrent_monitorset:fetch(Pid, Peers),
     NewReqs  = gb_trees:delete({PieceIndex, Offset}, OpenReqs),
     NewPeers = etorrent_monitorset:update(Pid, NewReqs, Peers),
 
     %% Add the chunk back to the chunkset of the piece.
     Chunks = array:get(PieceIndex, PieceChunks),
     NewChunks = etorrent_chunkset:insert(Offset, Length, Chunks),
     NewPieceChunks = array:set(PieceIndex, NewChunks, PieceChunks),
 
     NewState = State#state{
         piece_chunks=NewPieceChunks,
         peer_monitors=NewPeers},
    {reply, ok, NewState};

handle_call({mark_all_dropped, Pid}, _, State) ->
    #state{
        piece_chunks=PieceChunks,
        peer_monitors=Peers} = State,
    %% Add the chunks back to the chunkset of each piece.
    OpenReqs = etorrent_monitorset:fetch(Pid, Peers),
    NewPieceChunks = lists:foldl(fun({PieceIndex, Offset, Length}, Acc) ->
        insert_chunk(PieceIndex, Offset, Length, Acc)
    end, PieceChunks, chunk_list(OpenReqs)),
    %% Replace the peer's set of open requests with an empty set
    NewPeers = etorrent_monitorset:update(Pid, gb_trees:empty(), Peers),
    NewState = State#state{
        piece_chunks=NewPieceChunks,
        peer_monitors=NewPeers},
    {reply, ok, NewState}.



handle_cast(_, _) ->
    not_implemented.

handle_info({'DOWN', _, process, Pid, _}, State) ->
    #state{
        piece_chunks=PieceChunks,
        peer_monitors=Peers} = State,
    %% Add the chunks back to the chunkset of each piece.
    OpenReqs = etorrent_monitorset:fetch(Pid, Peers),
    NewPieceChunks = lists:foldl(fun({PieceIndex, Offset, Length}, Acc) ->
        insert_chunk(PieceIndex, Offset, Length, Acc)
    end, PieceChunks, chunk_list(OpenReqs)),
    %% Delete the peer from the set of monitored peers
    NewPeers = etorrent_monitorset:delete(Pid, Peers),
    NewState = State#state{
        piece_chunks=NewPieceChunks,
        peer_monitors=NewPeers},
    {noreply, NewState}.

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

%%
%% Given a piece index and an array of chunksets for each piece,
%% insert a chunk into the chunkset at the piece index.
%%
-spec insert_chunk(pos_integer(), pos_integer(),
                   pos_integer, array()) -> array().
insert_chunk(Piece, Offset, Length, PieceChunks) ->
    Chunks = array:get(Piece, PieceChunks),
    NewChunks = etorrent_chunkset:insert(Offset, Length, Chunks),
    array:set(Piece, NewChunks, PieceChunks).

-ifdef(TEST).
-define(chunk_server, ?MODULE).


initial_chunk_server(ID) ->
    {ok, Pid} = ?chunk_server:start_link(ID, 1, [], [{0, 2}, {1, 2}, {2, 2}]),
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
         ?_test(mark_valid_stored_case())
        ]}.

lookup_registered_case() ->
    ?assertEqual(true, ?chunk_server:register_chunk_server(0)),
    ?assertEqual(self(), ?chunk_server:lookup_chunk_server(0)).

unregister_case() ->
    ?assertEqual(true, ?chunk_server:register_chunk_server(3)),
    ?assertEqual(true, ?chunk_server:unregister_chunk_server(3)),
    ?assertError(badarg, ?chunk_server:lookup_chunk_server(3)).

not_interested_case() ->
    Srv = initial_chunk_server(1),
    Has = etorrent_pieceset:from_list([], 3),
    Ret = ?chunk_server:request_chunks(1, Has, 1),
    ?assertEqual({error, not_interested}, Ret).

not_interested_valid_case() ->
    ID = 9,
    {ok, Srv} = ?chunk_server:start_link(ID, 1, [0], [{0, 2}, {1, 2}, {2, 2}]),
    true = ?chunk_server:register_peer(ID),
    Has = etorrent_pieceset:from_list([0], 3),
    Ret = ?chunk_server:request_chunks(ID, Has, 1),
    ?assertEqual({error, not_interested}, Ret).

request_one_case() ->
    Srv = initial_chunk_server(2),
    Has = etorrent_pieceset:from_list([0], 3),
    Ret = ?chunk_server:request_chunks(1, Has, 1),
    ?assertEqual({ok, [{0, 0, 1}]}, Ret).

mark_dropped_case() ->
    Srv = initial_chunk_server(4),
    Has = etorrent_pieceset:from_list([0], 3),
    {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(4, Has, 1),
    {ok, [{0, 1, 1}]} = ?chunk_server:request_chunks(4, Has, 1),
    ok  = ?chunk_server:mark_dropped(4, 0, 0, 1),
    Ret = ?chunk_server:request_chunks(4, Has, 1),
    ?assertEqual({ok, [{0, 0, 1}]}, Ret).

mark_all_dropped_case() ->
    Srv = initial_chunk_server(5),
    Has = etorrent_pieceset:from_list([0], 3),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunk_server:request_chunks(5, Has, 1)),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunk_server:request_chunks(5, Has, 1)),
    ok = ?chunk_server:mark_all_dropped(5),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunk_server:request_chunks(5, Has, 1)),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunk_server:request_chunks(5, Has, 1)).

drop_all_on_exit_case() ->
    Srv = initial_chunk_server(6),
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() ->
        true = ?chunk_server:register_peer(6),
        {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(6, Has, 1),
        {ok, [{0, 1, 1}]} = ?chunk_server:request_chunks(6, Has, 1)
    end),
    Ref = monitor(process, Pid),
    ok  = receive {'DOWN', _, process, Pid, _} -> ok end,
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunk_server:request_chunks(6, Has, 1)),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunk_server:request_chunks(6, Has, 1)).

drop_none_on_exit_case() ->
    Srv = initial_chunk_server(7),
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() -> true = ?chunk_server:register_peer(7) end),
    Ref = monitor(process, Pid),
    ok  = receive {'DOWN', _, process, Pid, _} -> ok end,
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunk_server:request_chunks(7, Has, 1)),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunk_server:request_chunks(7, Has, 1)).

marked_stored_not_dropped_case() ->
    Srv = initial_chunk_server(8),
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() ->
        true = ?chunk_server:register_peer(8),
        {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(8, Has, 1),
        ok = ?chunk_server:mark_stored(8, 0, 0, 1)
    end),
    Ref = monitor(process, Pid),
    ok  = receive {'DOWN', _, process, Pid, _} -> ok end,
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunk_server:request_chunks(8, Has, 1)).

mark_fetched_noop_case() ->
    Srv = initial_chunk_server(10),
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() ->
        true = ?chunk_server:register_peer(10),
        {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(10, Has, 1),
        ok = ?chunk_server:mark_fetched(10, 0, 0, 1)
    end),
    Ref = monitor(process, Pid),
    ok  = receive {'DOWN', _, process, Pid, _} -> ok end,
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunk_server:request_chunks(10, Has, 1)).


mark_valid_not_stored_case() ->
    Srv = initial_chunk_server(11),
    Has = etorrent_pieceset:from_list([0], 3),
    Ret = ?chunk_server:mark_valid(11, 0),
    ?assertEqual({error, not_stored}, Ret).

mark_valid_stored_case() ->
    Srv = initial_chunk_server(12),
    Has = etorrent_pieceset:from_list([0,1], 3),
    {ok, [{0, 0, 1}]} = ?chunk_server:request_chunks(12, Has, 1),
    {ok, [{0, 1, 1}]} = ?chunk_server:request_chunks(12, Has, 1),
    ok  = ?chunk_server:mark_stored(12, 0, 0, 1),
    ok  = ?chunk_server:mark_stored(12, 0, 1, 1),
    ?assertEqual(ok, ?chunk_server:mark_valid(12, 0)).

-endif.
