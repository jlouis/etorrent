%%%-------------------------------------------------------------------
%%% File    : etorrent_chunk_mgr.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Chunk manager of etorrent.
%%%
%%% Created : 20 Jul 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------
-module(etorrent_chunk_mgr).

-include("etorrent_piece.hrl").
-include("etorrent_chunk.hrl").

-behaviour(gen_server).

%% API
-export([start_link/0, store_chunk/4, putback_chunks/1,
         putback_chunk/2, mark_fetched/2, pick_chunks/4,
         endgame_remove_chunk/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {}).
-define(SERVER, ?MODULE).
-define(STORE_CHUNK_TIMEOUT, 20).
-define(PICK_CHUNKS_TIMEOUT, 20).
-define(DEFAULT_CHUNK_SIZE, 16384).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% Function: mark_fetched/2
%% Args:  Id  ::= integer() - torrent id
%%        IOL ::= {integer(), integer(), integer()} - {Index, Offs, Len}
%% Description: Mark a given chunk as fetched.
%%--------------------------------------------------------------------
mark_fetched(Id, {Index, Offset, Len}) ->
    gen_server:call(?SERVER, {mark_fetched, Id, Index, Offset, Len}).

%% Store the chunk in the chunk table. As a side-effect, check the piece if it
%% is fully fetched.
store_chunk(Id, {Index, D, Ops}, {Offset, Len}, FSPid) ->
    gen_server:call(?SERVER, {store_chunk, Id, {Index, D, Ops}, {Offset, Len}, FSPid},
                   timer:seconds(?STORE_CHUNK_TIMEOUT)).

%%--------------------------------------------------------------------
%% Function: putback_chunks(Pid) -> transaction
%% Description: Find all chunks assigned to Pid and mark them as not_fetched
%%--------------------------------------------------------------------
putback_chunks(Pid) ->
    gen_server:cast(?SERVER, {putback_chunks, Pid}).

putback_chunk(Pid, {Idx, Offset, Len}) ->
    gen_server:cast(?SERVER, {putback_chunk, Pid, {Idx, Offset, Len}}).

%%--------------------------------------------------------------------
%% Function: endgame_remove_chunk/3
%% Args:  Pid ::= pid()     - pid of caller
%%        Id  ::= integer() - torrent id
%%        IOL ::= {integer(), integer(), integer()} - {Index, Offs, Len}
%% Description: Remove a chunk in the endgame from its assignment to a
%%   given pid
%%--------------------------------------------------------------------
endgame_remove_chunk(Pid, Id, {Index, Offset, Len}) ->
    gen_server:call(?SERVER, {endgame_remove_chunk, Pid, Id, {Index, Offset, Len}}).

%% Description: Return some chunks for downloading.
%%
%%   This function is relying on tail-calls to itself with different
%%   tags to return the needed data.
%%
%%--------------------------------------------------------------------
pick_chunks(_Pid, _Id, unknown, _N) ->
    none_eligible;
pick_chunks(Pid, Id, Set, N) ->
    gen_server:call(?SERVER, {pick_chunks, Pid, Id, Set, N},
                    timer:seconds(?PICK_CHUNKS_TIMEOUT)).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([]) ->
    _Tid = ets:new(etorrent_chunk_tbl, [set, protected, named_table,
                                        {keypos, 2}]),
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({mark_fetched, Id, Index, Offset, _Len}, _From, S) ->
    Res = case ets:lookup(etorrent_chunk_tbl, {Id, Index, not_fetched}) of
              [] -> assigned;
              [R] -> case lists:keymember(Offset, 1, R#chunk.chunks) of
                         true -> case lists:keydelete(Offset, 1, R#chunk.chunks) of
                                     [] -> ets:delete_object(etorrent_chunk_tbl, R);
                                     NC -> ets:insert(etorrent_chunk_tbl,
                                                      R#chunk { chunks = NC })
                                 end,
                                 found;
                         false -> assigned
                     end
        end,
    {reply, Res, S};
handle_call({endgame_remove_chunk, Pid, Id, {Index, Offset, _Len}}, _From, S) ->
    Res = case ets:lookup(etorrent_chunk_tbl, {Id, Index, {assigned, Pid}}) of
              [] -> ok;
              [R] -> case lists:keydelete(Offset, 1, R#chunk.chunks) of
                         [] -> ets:delete_object(etorrent_chunk_tbl, R);
                         NC -> ets:insert(etorrent_chunk_tbl,
                                          R#chunk { chunks = NC })
                     end
          end,
    {reply, Res, S};
%% TODO: This can be async.
handle_call({store_chunk, Id, {Index, Data, Ops},
                    {Offset, Len}, FSPid}, {Pid, _Tag}, S) ->
    ok = etorrent_fs:write_chunk(FSPid, {Index, Data, Ops}),
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
    {reply, ok, S};
handle_call({pick_chunks, Pid, Id, Set, Remaining}, _From, S) ->
    R = case pick_chunks(pick_chunked, {Pid, Id, Set, [], Remaining, none}) of
            not_interested -> pick_chunks_endgame(Id, Set, Remaining, not_interested);
            {ok, []}       -> pick_chunks_endgame(Id, Set, Remaining, none_eligible);
            {ok, Items}    -> {ok, Items}
        end,
    {reply, R, S};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({putback_chunk, Pid, {Idx, Offset, Len}}, S) ->
    for_each_chunk(
      Pid, Idx,
      fun (C) ->
              {Id, _, _} = C#chunk.idt,
              Chunks = C#chunk.chunks,
              NotFetchIdt = {Id, Idx, not_fetched},
              case ets:lookup(etorrent_chunk_tbl, NotFetchIdt) of
                  [] ->
                      ets:insert(etorrent_chunk_tbl,
                                 #chunk { idt = NotFetchIdt,
                                          chunks = [{Idx, Offset, Len}]});
                  [R] ->
                      ets:insert(etorrent_chunk_tbl,
                                 R#chunk { chunks = [{Idx, Offset, Len} |
                                                     R#chunk.chunks]})
              end,
              case lists:delete({Idx, Offset, Len}, Chunks) of
                  [] -> ets:delete_object(etorrent_chunk_tbl, C);
                  NewList -> ets:insert(etorrent_chunk_tbl,
                                        C#chunk { chunks = NewList })
              end
      end),
    {noreply, S};
handle_cast({putback_chunks, Pid}, S) ->
    for_each_chunk(
      Pid,
      fun(C) ->
              {Id, Idx, _} = C#chunk.idt,
              Chunks = C#chunk.chunks,
              NotFetchIdt = {Id, Idx, not_fetched},
              case ets:lookup(etorrent_chunk_tbl, NotFetchIdt) of
                  [] ->
                      ets:insert(etorrent_chunk_tbl,
                                 #chunk { idt = NotFetchIdt,
                                          chunks = Chunks});
                  [R] ->
                      ets:insert(etorrent_chunk_tbl,
                                 R#chunk { chunks = R#chunk.chunks ++ Chunks})
              end,
              ets:delete_object(etorrent_chunk_tbl, C)
      end),
    {noreply, S};
handle_cast(Msg, State) ->
    error_logger:error_report([unknown_msg, Msg]),
    {noreply, State}.


%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: find_remaining_chunks(Id, PieceSet) -> [Chunk]
%% Description: Find all remaining chunks for a torrent matching PieceSet
%%--------------------------------------------------------------------
find_remaining_chunks(Id, PieceSet) ->
    %% Note that the chunk table is often very small.
    MatchHeadAssign = #chunk { idt = {Id, '$1', {assigned, '_'}}, chunks = '$2'},
    MatchHeadNotFetch = #chunk { idt = {Id, '$1', not_fetched}, chunks = '$2'},
    RowsA = ets:select(etorrent_chunk_tbl, [{MatchHeadAssign, [], [{{'$1', '$2'}}]}]),
    RowsN = ets:select(etorrent_chunk_tbl, [{MatchHeadNotFetch, [], [{{'$1', '$2'}}]}]),
    Eligible = [{PN, Chunks} || {PN, Chunks} <- RowsA ++ RowsN,
                                gb_sets:is_element(PN, PieceSet)],
    [{PN, Os, Sz, Ops} || {PN, Chunks} <- Eligible,
                          {Os, Sz, Ops} <- Chunks].

%%--------------------------------------------------------------------
%% Function: chunkify_new_piece(Id, PieceSet) -> ok | none_eligible
%% Description: Find a piece in the PieceSet which has not been chunked
%%  yet and chunk it. Returns either ok if a piece was chunked or none_eligible
%%  if we can't find anything to chunk up in the PieceSet.
%%
%%--------------------------------------------------------------------
chunkify_new_piece(Id, PieceSet) when is_integer(Id) ->
    case etorrent_piece_mgr:find_new(Id, PieceSet) of
        none -> none_eligible;
        P when is_record(P, piece) ->
            chunkify_piece(Id, P),
            ok
    end.

%%--------------------------------------------------------------------
%% Function: select_chunks_by_piecenum(Id, PieceNum, Num, Pid) ->
%%     {ok, [{Offset, Len}], Remain}
%% Description: Select up to Num chunks from PieceNum. Will return either
%%  {ok, Chunks} if it got all chunks it wanted, or {partial, Chunks, Remain}
%%  if it got some chunks and there is still Remain chunks left to pick.
%%--------------------------------------------------------------------
select_chunks_by_piecenum(Id, Index, N, Pid) ->
    [R] = ets:lookup(etorrent_chunk_tbl,
                    {Id, Index, not_fetched}),
    %% Get up to N chunks
    {Return, Rest} = etorrent_utils:gsplit(N, R#chunk.chunks),
    [_|_] = Return, %% Assert.
    %% Write back missing chunks.
    case Rest of
        [] -> ets:delete_object(etorrent_chunk_tbl, R);
        [_|_] -> ets:insert(etorrent_chunk_tbl, R#chunk { chunks = Rest})
    end,
    %% Assign chunk to us
    Q = case ets:lookup(etorrent_chunk_tbl, {Id, Index, {assigned, Pid}}) of
            [] ->
                #chunk { idt = {Id, Index, {assigned, Pid}},
                         chunks = [] };
            [C] -> C
        end,
    ets:insert(etorrent_chunk_tbl, Q#chunk { chunks = Return ++ Q#chunk.chunks}),
    %% Tell caller how much is remaning
    Remaining = N - length(Return),
    {ok, {Index, Return}, Remaining}.

%% Check the piece Idx on torrent Id for completion
check_piece(FSPid, Id, Idx) ->
    etorrent_fs:check_piece(FSPid, Idx),
    MatchHead = #chunk { idt = {Id, Idx, '_'}, _ = '_'},
    ets:select_delete(etorrent_chunk_tbl,
                      [{MatchHead, [], [true]}]).

%%--------------------------------------------------------------------
%% Function: chunkify(Operations) ->
%%  [{Offset, Size, FileOperations}]
%% Description: From a list of operations to read/write a piece, construct
%%   a list of chunks given by Offset of the chunk, Size of the chunk and
%%   how to read/write that chunk.
%%--------------------------------------------------------------------

%% First, we call the version of the function doing the grunt work.
chunkify(Operations) ->
    chunkify(0, 0, [], Operations, ?DEFAULT_CHUNK_SIZE).

%% Suppose the next File operation on the piece has 0 bytes in size, then it
%%  is exhausted and must be thrown away.
chunkify(AtOffset, EatenBytes, Operations,
         [{_Path, _Offset, 0} | Rest], Left) ->
    chunkify(AtOffset, EatenBytes, Operations, Rest, Left);

%% There are no more file operations to carry out. Hence we reached the end of
%%   the piece and we just return the last chunk operation. Remember to reverse
%%   the list of operations for that chunk as we build it in reverse.
chunkify(AtOffset, EatenBytes, Operations, [], _Sz) ->
    [{AtOffset, EatenBytes, lists:reverse(Operations)}];

%% There are no more bytes left to add to this chunk. Recurse by calling
%%   on the rest of the problem and add our chunk to the front when coming
%%   back. Remember to reverse the Operations list built in reverse.
chunkify(AtOffset, EatenBytes, Operations, OpsLeft, 0) ->
    R = chunkify(AtOffset + EatenBytes, 0, [], OpsLeft, ?DEFAULT_CHUNK_SIZE),
    [{AtOffset, EatenBytes, lists:reverse(Operations)} | R];

%% The next file we are processing have a larger size than what is left for this
%%   chunk. Hence we can just eat off that many bytes from the front file.
chunkify(AtOffset, EatenBytes, Operations,
         [{Path, Offset, Size} | Rest], Left) when Left =< Size ->
    chunkify(AtOffset, EatenBytes + Left,
             [{Path, Offset, Left} | Operations],
             [{Path, Offset+Left, Size - Left} | Rest],
             0);

%% The next file does *not* have enough bytes left, so we eat all the bytes
%%   we can get from it, and move on to the next file.
chunkify(AtOffset, EatenBytes, Operations,
        [{Path, Offset, Size} | Rest], Left) when Left > Size ->
    chunkify(AtOffset, EatenBytes + Size,
             [{Path, Offset, Size} | Operations],
             Rest,
             Left - Size).

%%--------------------------------------------------------------------
%% Function: chunkify_piece(Id, PieceNum) -> ok
%% Description: Given a PieceNumber, cut it up into chunks and add those
%%   to the chunk table.
%%--------------------------------------------------------------------
chunkify_piece(Id, P) when is_record(P, piece) ->
    Chunks = chunkify(P#piece.files),
    NumChunks = length(Chunks),
    not_fetched = P#piece.state,
    {Id, Idx} = P#piece.idpn,
    ok = etorrent_piece_mgr:chunk(Id, Idx, NumChunks),
    ets:insert(etorrent_chunk_tbl,
               #chunk { idt = {Id, Idx, not_fetched},
                        chunks = Chunks}),
    etorrent_torrent:decrease_not_fetched(Id),
    ok.

%%--------------------------------------------------------------------
%% Function: find_chunked_chunks(Id, iterator_result()) -> none | PieceNum
%% Description: Search an iterator for a chunked piece.
%%--------------------------------------------------------------------
find_chunked_chunks(_Id, none, Res) -> Res;
find_chunked_chunks(Id, {Pn, Next}, Res) ->
    case etorrent_piece_mgr:is_chunked(Id, Pn) of
        true ->
            case ets:lookup(etorrent_chunk_tbl, {Id, Pn, not_fetched}) of
                [] ->
                    find_chunked_chunks(Id, gb_sets:next(Next), found_chunked);
                _ ->
                    Pn
            end;
        false ->
            find_chunked_chunks(Id, gb_sets:next(Next), Res)
    end.

update_fetched(Id, Index, {Offset, _Len}) ->
    case etorrent_piece_mgr:fetched(Id, Index) of
        true -> fetched;
        false ->
            case ets:lookup(etorrent_chunk_tbl,
                            {Id, Index, fetched}) of
                [] ->
                    ets:insert(etorrent_chunk_tbl,
                               #chunk { idt = {Id, Index, fetched},
                                        chunks = [Offset]}),
                    false;
                [R] ->
                    case lists:member(Offset, R#chunk.chunks) of
                        true -> true;
                        false ->
                            ets:insert(etorrent_chunk_tbl,
                                       R#chunk { chunks = [ Offset | R#chunk.chunks]}),
                            false
                    end
            end
    end.

update_chunk_assignment(Id, Index, Pid,
                        {Offset, Len}) ->
    case ets:lookup(etorrent_chunk_tbl,
                    {Id, Index, {assigned, Pid}}) of
        [] ->
            %% Stored a chunk not belonging to us, ignore
            ok;
        [S] ->
            case lists:keydelete({Offset, Len}, 1, S#chunk.chunks) of
                [] ->
                    ets:delete_object(etorrent_chunk_tbl, S);
                L when is_list(L) ->
                    ets:insert(etorrent_chunk_tbl,
                               S#chunk { chunks = L })
            end
    end.

%%
%% There are 0 remaining chunks to be desired, return the chunks so far
pick_chunks(_Operation, {_Pid, _Id, _PieceSet, SoFar, 0, _Res}) ->
    {ok, SoFar};
%%
%% Pick chunks from the already chunked pieces
pick_chunks(pick_chunked, {Pid, Id, PieceSet, SoFar, Remaining, Res}) ->
    Iterator = gb_sets:iterator(PieceSet),
    case find_chunked_chunks(Id, gb_sets:next(Iterator), Res) of
        none ->
            pick_chunks(chunkify_piece, {Pid, Id, PieceSet, SoFar, Remaining, none});
        found_chunked ->
            pick_chunks(chunkify_piece, {Pid, Id, PieceSet, SoFar, Remaining, found_chunked});
        PieceNum when is_integer(PieceNum) ->
            {ok, Chunks, Left} =
                select_chunks_by_piecenum(Id, PieceNum,
                                          Remaining, Pid),
            pick_chunks(pick_chunked, {Pid, Id,
                                       gb_sets:del_element(PieceNum, PieceSet),
                                       [Chunks | SoFar],
                                       Left, Res})
    end;

%%
%% Find a new piece to chunkify. Give up if no more pieces can be chunkified
pick_chunks(chunkify_piece, {Pid, Id, PieceSet, SoFar, Remaining, Res}) ->
    case chunkify_new_piece(Id, PieceSet) of
        ok ->
            pick_chunks(pick_chunked, {Pid, Id, PieceSet, SoFar, Remaining, Res});
        none_eligible when SoFar =:= [], Res =:= none ->
            not_interested;
        none_eligible when SoFar =:= [], Res =:= found_chunked ->
            {ok, []};
        none_eligible ->
            {ok, SoFar}
    end;
%%
%% Handle the endgame for a torrent gracefully
pick_chunks(endgame, {Id, PieceSet, N}) ->
    Remaining = find_remaining_chunks(Id, PieceSet),
    Shuffled = etorrent_utils:shuffle(Remaining),
    {endgame, lists:sublist(Shuffled, N)}.


pick_chunks_endgame(Id, Set, Remaining, Ret) ->
    case etorrent_torrent:is_endgame(Id) of
        false -> Ret; %% No endgame yet
        true -> pick_chunks(endgame, {Id, Set, Remaining})
    end.

for_each_chunk(Pid, F) when is_pid(Pid) ->
    MatchHead = #chunk { idt = {'_', '_', {assigned, Pid}}, _ = '_'},
    for_each_chunk(MatchHead, F);
for_each_chunk(MatchHead, F) ->
    Rows = ets:select(etorrent_chunk_tbl, [{MatchHead, [], ['$_']}]),
    lists:foreach(F, Rows),
    ok.

for_each_chunk(Pid, Idx, F) when is_integer(Idx) ->
    MatchHead = #chunk { idt = {'_', Idx, {assigned, Pid}}, _ = '_'},
    for_each_chunk(MatchHead, F).

