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

-include("types.hrl").
-include("log.hrl").

-include_lib("stdlib/include/ms_transform.hrl").

-behaviour(gen_server).

%% @todo: What pid is the chunk recording pid? Control or SendPid?
%% API
-export([start_link/1,
         store_chunk/4,
         putback_chunks/1,
         mark_fetched/2,
         pick_chunks/3,
         endgame_remove_chunk/3]).

%% gproc registry entries
-export([register_chunk_server/1,
         unregister_chunk_server/1,
         lookup_chunk_server/1]).


%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-type chunkset()   :: etorrent_chunkset:chunkset().
-type pieceset()   :: etorrent_pieceset:pieceset().
-type monitorset() :: etorrent_monitorset:monitorset().

-record(state, {
    pieces_valid   :: pieceset(),
    pieces_chunked :: pieceset(),
    piece_chunks   :: array(),
    peer_monitors  :: monitorset()}).


-spec register_chunk_server(torrentid()) -> true.
register_chunk_server(TorrentID) ->
    gproc:reg({n, l, chunk_server_key(TorrentID)}).

-spec unregister_chunk_server(torrentid()) -> true.
unregister_chunk_server(TorrentID) ->
    gproc:unreg({n, l, chunk_server_key(TorrentID)}).

-spec lookup_chunk_server(torrentid()) -> pid().
lookup_chunk_server(TorrentID) ->
    gproc:whereis({n, l, chunk_server_key(TorrentID}).

chunk_server_key(TorrentID) ->
    {etorrent, TorrentID, chunk_server}.


    
%%===================================================================
-spec start_link(torrentid()) -> ignore | {ok, pid()} | {error, any()}.
start_link(TorrentID) ->
    gen_server:start_link(?MODULE, [TorrentID], []).

%% @doc Mark a given chunk as fetched.
%% @end
-spec mark_fetched(integer(), {integer(), integer(), integer()}) -> found | assigned.
mark_fetched(TorrentID, {Index, Offset, Len}) ->
    gen_server:call(?SERVER, {mark_fetched, Id, Index, Offset, Len}).

%% @doc Store the chunk in the chunk table.
%%   As a side-effect, check the piece if it is fully fetched.
%% @end
-spec store_chunk(integer(), {integer(), binary(), term()}, {integer(), integer()}, pid()) ->
                ok.
store_chunk(Id, {Index, D, Ops}, {Offset, Len}, FSPid) ->
    gen_server:cast(?SERVER, {store_chunk, Id, self(), {Index, D, Ops}, {Offset, Len}, FSPid}).

%% @doc Find all chunks assigned to Pid and mark them as not_fetched
%%   This is called by a peer when the remote chokes.
%% @end
-spec putback_chunks(pid()) -> ok.
putback_chunks(Pid) ->
    gen_server:cast(?SERVER, {putback_chunks, Pid}).

%% @doc Remove a chunk in the endgame from its assignment
%% <p>This call forces the removal of a chunk from its assigned pid()
%% in endgame mode. It makes sure we strike out chunks which are being
%% downloaded by other peers than the peer it was originally assigned to.</p>
%% @end.
-spec endgame_remove_chunk(pid(), integer(), {integer(), integer(), integer()}) -> ok.
endgame_remove_chunk(SendPid, Id, {Index, Offset, Len}) ->
    gen_server:call(?SERVER, {endgame_remove_chunk, SendPid, Id, {Index, Offset, Len}},
		    infinity).

%% @doc Return some chunks for downloading.
%% @end
-type chunk_lst1() :: [{integer(), integer(), integer(), [operation()]}].
-type chunk_lst2() :: [{integer(), [#chunk{}]}].
-spec pick_chunks(torrent_id(), unknown | pieceset(), pos_integer()) ->
    none_eligible | not_interested | {ok | endgame, chunk_lst1() | chunk_lst2()}.
pick_chunks(_, unknown, _) ->
    none_eligible;
pick_chunks(TorrentID, Peerset, Numchunks) ->
    Chunkserver = lookup_chunk_server(TorrentID),
    gen_server:call(Chunkserver, {pick_chunks, Peerset, Numchunks}).


%% ----------------------------------------------------------------------
%% @doc Choose up to Max chunks from Selected.
%%  Will return {ok, {Index, Chunks}, size(Chunks)}.
%% @end
-spec select_chunks_by_piecenum({pos_integer(), pos_integer()}, pos_integer()) ->
			   {ok, {pos_integer(), term()}, non_neg_integer()} | {error, already_taken}.
select_chunks_by_piecenum({TorrentId, Pn}, Max) ->
    gen_server:call(?SERVER, {select_chunks_by_piecenum, {TorrentId, Pn}, Max},
		    infinity).


%%====================================================================

%% @private
init([TorrentID]) ->
    true = register_chunk_server(TorrentID),

    %% Load some information about this torrent from higher up
    %% in the supervisor-tree.
    {value, NumPieces} = etorrent_torrent:num_pieces(TorrentID),
    FetchedPieces = etorrent_piece_mgr:fetched(TorrentID),
    PiecesValid   = etorrent_pieceset:from_list(FetchedPieces, NumPieces),
    PiecesChunked = etorrent_pieceset:new(NumPieces),

    %% Initialize a full chunkset for all pieces that are left to download
    %% but don't mark them as chunked before a chunk has been deleted from
    %% any of the chunksets.
    AllIndexes = lists:seq(0, NumPieces - 1),
    AllPieces = etorrent_pieceset:from_list(AllIndexes, NumPieces),
    PiecesInvalid = etorrent_pieceset:difference(AllPieces, PiecesValid),
    ChunkList = [begin
        Size = etorrent_io:piece_size(TorrentID, N)
        Set  = etorrent_chunkset:new(Size, 16#4000),
        {N, Set}
    end || N <- etorrent_pieceset:to_list(PiecesInvalid)],

    %% Initialize an empty chunkset for all pieces that are valid.
    CompletedList = [begin
        Size = etorrent_io:piece_size(TorrentID, N),
        Set  = etorrent_chunkset:from_list(Size, 16#4000, []),
        {N, Set}
    end || N <- etorrent_pieceset:to_list(PiecesValid)],

    AllChunksets = lists:sort(CompletedList ++ ChunkList),
    PieceChunks  = array:from_ordict(AllChunksets),

    InitState = #state{
        pieces_valid=PiecesValid,
        pieces_chunked=PiecesChunked,
        piece_chunks=PieceChunks,
        peer_monitors=etorrent_monitorset:new()},
    {ok, InitState}.


handle_call({pick_chunks, Peerset, Numchunks}, _, State) ->
    #state{
        pieces_valid=PiecesValid,
        pieces_chunked=PiecesChunked,
        piece_chunks=PieceChunks} = State,
    
    %% If this peer has no pieces that we are already downloading, begin
    %% downloading a new piece if this peer has any interesting pieces.
    OptimalPieces    = etorrent_pieceset:intersection(Peerset, PiecesValid),
    SubOptimalPieces = etorrent_pieceset:difference(Peerset, PiecesValid),
    NumOptimal    = etorrent_pieceset:size(OptimalPieces),
    NumSubOptimal = etorrent_pieceset:size(SubOptimalPieces),

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
            etorrent_pieceset:min(OpimalPieces)
    end,

    case PieceIndex of
        none ->
            {reply, {error, not_interested}, State};
        PieceIndex ->
            Chunkset    = array:get(PieceIndex, PieceChunks),
            {Offs, Len} = etorrent_chunkset:min(Chunkset),
            NewChunkset = etorrent_chunkset:delete(Offset, Len, Chunkset),
            NewChunks   = array:set(PieceIndex, NewChunkset, PieceChunks),
            NewChunked  = etorrent_pieceset:insert(PieceIndex, PiecesChunked),
            NewState = State#state{
                pieces_chunked=NewChunked,
                piece_chunks=NewChunks},
            {reply, {ok, [{PieceIndex, Offset, Len}]}, NewState}
    end;


handle_call({mark_fetched, Id, Index, Offset, _Len}, _From, S) ->
    case ets:match_object(?TAB, #chunk { idt = {Id, Index, not_fetched},
					 chunk = {Offset, '_', '_'} }) of
	[] -> {reply, assigned, S};
	[Obj] -> ets:delete_object(?TAB, Obj),
		 {reply, found, S}
    end;
%% @todo: If we have an idt with {assigned, pid()}, do we have chunk = Offset?
handle_call({select_chunks_by_piecenum, {Id, Pn}, Max}, {Pid, _Tag}, S) ->
    case ets:lookup(?TAB, {Id, Pn, not_fetched}) of
	[] ->
	    {reply, {error, already_taken}, S};
	Selected when is_list(Selected) ->
	    %% Get up to Max chunks
	    {Return, _Rest} = etorrent_utils:gsplit(Max, Selected),
	    %% Assign chunk to Pid
	    Chunks = [begin
			  ets:delete_object(?TAB, C),
			  ets:insert(?TAB,
				     [C#chunk {
				idt = {Id, Pn, {assigned, Pid}} }]),
			  C#chunk.chunk
		      end || C <- Return],
	    MP = ensure_monitor(Pid, S#state.monitored_peers),
	    {reply,
	     {ok, {Pn, Chunks}, length(Chunks)},
	     S#state { monitored_peers = MP }}
    end;
handle_call({chunkify_piece, {Id, Pn}}, _From, S) ->
    chunkify_piece(Id, Pn),
    {reply, ok, S};
handle_call({endgame_remove_chunk, SendPid, Id, {Index, Offset, _Len}},
            _From, S) ->
    ets:match_delete(?TAB,
		      #chunk { idt = {Id, Index, {assigned, SendPid}},
			       chunk = Offset }),
    {reply, ok, S};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

ensure_monitor(Pid, Set) ->
    case gb_sets:is_member(Pid, Set) of
	true ->
	    Set;
	false ->
	    erlang:monitor(process, Pid),
	    gb_sets:add(Pid, Set)
    end.

%% @private
handle_cast({store_chunk, Id, Pid, {Index, Data, Ops}, {Offset, Len}, FSPid}, S) ->
    ok = etorrent_io:write_chunk(Id, Index, Offset, Data),
    %% Add the newly fetched data to the fetched list
    Present = update_fetched(Id, Index, {Offset, Len}),
    %% Update chunk assignment
    update_chunk_assignment(Id, Index, Pid, {Offset, Len}),
    %% Countdown number of missing chunks
    case Present of
        fetched -> ok;
        true    -> ok;
        false   ->
            case etorrent_piece_mgr:decrease_missing_chunks(Id, Index) of
                full -> check_piece(FSPid, Id, Index);
                X    -> X
            end
    end,
    {noreply, S};
% @todo This only works if {assigned, pid()} has chunks as a 3-tuple
handle_cast({putback_chunks, Pid}, S) ->
    remove_chunks_for_pid(Pid),
    {noreply, S};
handle_cast(Msg, State) ->
    ?WARN([unknown_msg, Msg]),
    {noreply, State}.

%% @private
handle_info({'DOWN', _Ref, process, Pid, _Reason}, S) ->
    case dict:find(Pid, S#state.torrent_dict) of
	{ok, Id} ->
	    clear_torrent_entries(Id),
	    ManageDict = dict:erase(Pid, S#state.torrent_dict),
	    {noreply, S#state { torrent_dict = ManageDict }};
	error ->
	    %% Not found, assume it is a Pid of a process
	    remove_chunks_for_pid(Pid),
	    {noreply, S#state { monitored_peers =
				  gb_sets:del_element(Pid,
						      S#state.monitored_peers) }}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%--------------------------------------------------------------------

%% @doc Find all entries for a given torrent file and clear them out
%% @end
clear_torrent_entries(Id) ->
    ets:match_delete(?TAB, #chunk { idt = {Id, '_', '_'}, chunk = '_'}).

%% @doc Find all remaining chunks for a torrent matching PieceSet
%% @end
%% @todo Consider using ets:fun2ms here to parse-transform the matches
-spec find_remaining_chunks(integer(), set()) ->
    [{integer(), integer(), integer(), [operation()]}].
find_remaining_chunks(Id, PieceSet) ->
    %% Note that the chunk table is often very small.
    MatchHeadAssign = #chunk { idt = {Id, '$1', {assigned, '_'}}, chunk = '$2'},
    MatchHeadNotFetch = #chunk { idt = {Id, '$1', not_fetched}, chunk = '$2'},
    RowsA = ets:select(?TAB, [{MatchHeadAssign, [], [{{'$1', '$2'}}]}]),
    RowsN = ets:select(?TAB, [{MatchHeadNotFetch, [], [{{'$1', '$2'}}]}]),
    Eligible = [{PN, Chunk} || {PN, Chunk} <- RowsA ++ RowsN,
                                gb_sets:is_element(PN, PieceSet)],
    [{PN, Os, Sz, Ops} || {PN, {Os, Sz, Ops}} <- Eligible].

%% @doc Chunkify a new piece.
%%
%%  Find a piece in the PieceSet which has not been chunked
%%  yet and chunk it. Returns either ok if a piece was chunked or none_eligible
%%  if we can't find anything to chunk up in the PieceSet.
%%
%% @end
-spec chunkify_new_piece(integer(), gb_set()) -> {ok, pos_integer()} | none_eligible.
chunkify_new_piece(Id, PieceSet) when is_integer(Id) ->
    case etorrent_piece_mgr:find_new(Id, PieceSet) of
        none -> none_eligible;
        {P, Pn} when is_integer(Pn) ->
	    ok = gen_server:call(?SERVER, {chunkify_piece, {Id, P}},
				 infinity),
	    {ok, Pn}
    end.

%% Check the piece Idx on torrent Id for completion
check_piece(_, Id, Idx) ->
    _ = spawn_link(etorrent_io, check_piece_completion, [Id, Idx]),
    ets:match_delete(?TAB, #chunk { idt = {Id, Idx, '_'}, _ = '_'}).


%% @doc Add a chunked piece to the chunk table
%%   Given a PieceNumber, cut it up into chunks and add those
%%   to the chunk table.
%% @end
-spec chunkify_piece(integer(), etorrent:piece_mgr_piece()) -> ok. %% @todo: term() is #piece{}, opaque export it
chunkify_piece(Id, P) ->
    {Id, Idx, Chunks} = etorrent_piece_mgr:chunkify_piece(Id, P),
    ets:insert(?TAB, [#chunk { idt = {Id, Idx, not_fetched}, chunk = CH }
		      || CH <- Chunks]),
    etorrent_torrent:decrease_not_fetched(Id),
    ok.

%% @doc Search for piece chunks to download from a peer
%%   We are given an iterator of the pieces the peer has. We search the
%%   the iterator for a pieces we have already chunked and are downloading.
%%   If found, return the #chunk{} object. Otherwise return 'none'
%% @end
-spec find_chunked_chunks(pos_integer(), term(), A) -> A | pos_integer().
find_chunked_chunks(_Id, none, Res) -> Res;
find_chunked_chunks(Id, {Pn, Iter}, _Res) ->
    case ets:member(?TAB, {Id, Pn, not_fetched}) of
	false ->
	    find_chunked_chunks(Id, gb_sets:next(Iter), found_chunked);
	true ->
	    Pn
    end.

update_fetched(Id, Index, {Offset, _Len}) ->
    case etorrent_piece_mgr:fetched(Id, Index) of
        true -> fetched;
        false ->
	    case ets:match_object(?TAB, #chunk { idt = {Id, Index, fetched},
						 chunk = Offset }) of
		[] ->
		    ets:insert(?TAB,
			       #chunk { idt = {Id, Index, fetched},
					chunk = Offset }),
		    false;
		[_Obj] ->
		    true
	    end
    end.

update_chunk_assignment(Id, Index, Pid,
                        {Offset, _Len}) ->
    ets:match_delete(?TAB, #chunk { idt = {Id, Index, {assigned, Pid}},
				    chunk = {Offset, '_', '_'} }).

%%
%% There are 0 remaining chunks to be desired, return the chunks so far
pick_chunks(_Operation, {_Pid, _Id, _PieceSet, SoFar, 0, _Res}) ->
    {ok, SoFar};
%%
%% Pick chunks from the already chunked pieces
pick_chunks(pick_chunked, Tup = {_, Id, _, _, _, _}) ->
    Candidates = etorrent_piece_mgr:chunked_pieces(Id),
    CandidateSet = gb_sets:from_list(Candidates),
    pick_chunks({pick_among, CandidateSet}, Tup);
pick_chunks({pick_among, CandidateSet}, {Pid, Id, PieceSet, SoFar, Remaining, Res}) ->
    Iter = gb_sets:iterator( gb_sets:intersection(CandidateSet, PieceSet) ),
    case find_chunked_chunks(Id, gb_sets:next(Iter), Res) of
        none ->
            pick_chunks(chunkify_piece, {Pid, Id, PieceSet, SoFar, Remaining, none});
        found_chunked ->
            pick_chunks(chunkify_piece, {Pid, Id, PieceSet, SoFar, Remaining, found_chunked});
	PN when is_integer(PN) ->
	    case select_chunks_by_piecenum({Id, PN}, Remaining) of
		{ok, {PieceNum, Chunks}, Size} ->
		    pick_chunks(pick_chunked, {Pid, Id,
					       gb_sets:del_element(PieceNum, PieceSet),
					       [{PieceNum, Chunks} | SoFar],
					       Remaining - Size, Res});
		{error, already_taken} ->
		    %% So somebody else took this, try again
		    pick_chunks(pick_chunked, {Pid, Id, PieceSet, SoFar, Remaining, Res})
	    end
    end;

%%
%% Find a new piece to chunkify. Give up if no more pieces can be chunkified
pick_chunks(chunkify_piece, {Pid, Id, PieceSet, SoFar, Remaining, Res}) ->
    case chunkify_new_piece(Id, PieceSet) of
        {ok, P} ->
	    CandidateSet = gb_sets:from_list([P]),
            pick_chunks({pick_among, CandidateSet}, {Pid, Id, PieceSet, SoFar, Remaining, Res});
        none_eligible when SoFar =:= [], Res =:= none ->
            not_interested;
        none_eligible when SoFar =:= [], Res =:= found_chunked ->
            {ok, []};
        none_eligible ->
            {ok, SoFar}
    end;
%% Handle the endgame for a torrent gracefully
pick_chunks(endgame, {Id, PieceSet, N}) ->
    Remaining = find_remaining_chunks(Id, PieceSet),
    Shuffled = etorrent_utils:list_shuffle(Remaining),
    {endgame, lists:sublist(Shuffled, N)}.

-spec pick_chunks_endgame(integer(), gb_set(), integer(), X) -> X | {endgame, [#chunk{}]}.
pick_chunks_endgame(Id, Set, Remaining, Ret) ->
    case etorrent_torrent:is_endgame(Id) of
        false -> Ret; %% No endgame yet
        true -> pick_chunks(endgame, {Id, Set, Remaining})
    end.

remove_chunks_for_pid(Pid) ->
    for_each_chunk(
      Pid,
      fun(C) ->
	      {Id, Idx, _} = C#chunk.idt,
	      ets:insert(?TAB,
			 #chunk { idt = {Id, Idx, not_fetched},
				  chunk = C#chunk.chunk }),
	      ets:delete_object(?TAB, C)
      end).

for_each_chunk(Pid, F) when is_pid(Pid) ->
    MatchHead = #chunk { idt = {'_', '_', {assigned, Pid}}, _ = '_'},
    for_each_chunk(MatchHead, F);
for_each_chunk(MatchHead, F) ->
    Rows = ets:select(?TAB, [{MatchHead, [], ['$_']}]),
    lists:foreach(F, Rows),
    ok.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(chunk_server, ?MODULE).

chunk_server_registry_test() ->
    ?assertEqual(true, ?chunk_server:register_chunk_server(1)),
    ?assertEqual(self(), ?chunk_server:lookup_chunk_server(1)).


