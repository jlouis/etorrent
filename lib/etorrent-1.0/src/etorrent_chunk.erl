%%%-------------------------------------------------------------------
%%% File    : etorrent_mnesia_chunks.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Chunking code for mnesia.
%%%
%%% Created : 31 Mar 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_chunk).

-include_lib("stdlib/include/qlc.hrl").

-include("etorrent_mnesia_table.hrl").

-define(DEFAULT_CHUNK_SIZE, 16384). % Default size for a chunk. All clients use this.

%% API
-export([pick_chunks/4, store_chunk/4, putback_chunks/1,
	 endgame_remove_chunk/3, mark_fetched/2,
	 remove_chunks/2]).

%%====================================================================
%% API
%%====================================================================


%%--------------------------------------------------------------------
%% Function: pick_chunks(Handle, PieceSet, StatePid, Num) -> ...
%% Description: Return some chunks for downloading.
%%
%%   This function is relying on tail-calls to itself with different
%%   tags to return the needed data.
%%
%%--------------------------------------------------------------------
%% TODO, not_interested here does not take chunked pieces into account!
pick_chunks(Pid, Id, PieceSet, Remaining) ->
    case pick_chunks(pick_chunked, {Pid, Id, PieceSet, [], Remaining, none}) of
	not_interested -> pick_chunks_endgame(Id, PieceSet, Remaining,
					      not_interested);
	{ok, []}       -> pick_chunks_endgame(Id, PieceSet, Remaining,
					      none_eligible);
	{ok, Items}    -> {ok, Items}
    end.

pick_chunks_endgame(Id, PieceSet, Remaining, Ret) ->
    case etorrent_torrent:is_endgame(Id) of
	false -> Ret; %% No endgame yet
	true -> pick_chunks(endgame, {Id, PieceSet, Remaining})
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
	    {atomic, {ok, Chunks, Left}} =
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

%%--------------------------------------------------------------------
%% Function: putback_chunks(Pid) -> transaction
%% Description: Find all chunks assigned to Pid and mark them as not_fetched
%%--------------------------------------------------------------------
putback_chunks(Pid) ->
    MatchHead = #chunk { idt = {'_', '_', {assigned, Pid}}, _='_'},
    mnesia:transaction(
      fun () ->
	      Rows = mnesia:select(chunk, [{MatchHead, [], ['$_']}]),
	      lists:foreach(
		fun(C) ->
			{Id, PieceNum, _} = C#chunk.idt,
			Chunks = C#chunk.chunks,
			NotFetchIdt = {Id, PieceNum, not_fetched},
			case mnesia:read(chunk, NotFetchIdt, write) of
			    [] ->
				mnesia:write(#chunk{ idt = NotFetchIdt,
						     chunks = Chunks});
			    [R] ->
				mnesia:write(
				  R#chunk { chunks =
					    R#chunk.chunks ++ Chunks})
			end,
			mnesia:delete_object(C)
		end,
		Rows)
      end).

%%--------------------------------------------------------------------
%% Function: store_chunk(Id, PieceNum, {Offset, Len},
%%                       Data, FSPid, PeerGroupPid, Pid) -> ok
%% Description: Workhorse function. Store a chunk in the chunk mnesia table.
%%    If we have all chunks we need, then report the piece is full.
%%--------------------------------------------------------------------
store_chunk(Id, PieceNum, {Offset, Len}, Pid) ->
    {atomic, Res} =
	mnesia:transaction(
	  fun () ->
		  %% Add the newly fetched data to the fetched list
		  Present =
		      case mnesia:read(chunk, {Id, PieceNum, fetched}, write) of
			  [] ->
			      mnesia:write(#chunk { idt = {Id, PieceNum, fetched},
						    chunks = [Offset]}),
			      false;
			  [R] ->
			      mnesia:write(
				R#chunk { chunks =
					  [Offset | R#chunk.chunks]}),
			      lists:member(Offset, R#chunk.chunks)
		      end,
		  %% Update that the chunk is not anymore assigned to the Pid
		  case mnesia:read(chunk, {Id, PieceNum, {assigned, Pid}}, write) of
		      [] ->
			  %% We stored a chunk that was not belonging to us, do nothing
			  ok;
		      [S] ->
			  case lists:keydelete({Offset, Len}, 1, S#chunk.chunks) of
			      [] ->
				  mnesia:delete_object(S);
			      L when is_list(L) ->
				  mnesia:write(S#chunk { chunks = L })
			  end
		  end,
		  %% Count down the number of missing chunks for the piece
		  %% Next lines can be thrown into a seperate counter for speed.
		  case Present of
		      false ->
			  [P] = mnesia:read(piece, {Id, PieceNum}, write),
			  NewP = P#piece { left = P#piece.left - 1 },
			  mnesia:write(NewP),
			  case NewP#piece.left of
			      0 ->
				  full;
			      N when is_integer(N) ->
				  ok
			  end;
		      true ->
			  ok
		  end
	  end),
    Res.

%%--------------------------------------------------------------------
%% Function: endgame_remove_chunk/3
%% Args:  Pid ::= pid()     - pid of caller
%%        Id  ::= integer() - torrent id
%%        IOL ::= {integer(), integer(), integer()} - {Index, Offs, Len}
%% Description: Remove a chunk in the endgame from its assignment to a
%%   given pid
%%--------------------------------------------------------------------
endgame_remove_chunk(Pid, Id, {Index, Offset, _Len}) ->
    case mnesia:dirty_read(chunk, {Id, Index, {assigned, Pid}}) of
	[] ->
	    ok;
	[R] ->
	    NC = lists:keydelete(Offset, 1, R#chunk.chunks),
	    mnesia:dirty_write(R#chunk {chunks = NC})
    end.

%%--------------------------------------------------------------------
%% Function: mark_fetched/2
%% Args:  Id  ::= integer() - torrent id
%%        IOL ::= {integer(), integer(), integer()} - {Index, Offs, Len}
%% Description: Mark a given chunk as fetched.
%%--------------------------------------------------------------------
mark_fetched(Id, {Index, Offset, _Len}) ->
    F =	fun () ->
		case mnesia:read(chunk, {Id, Index, not_fetched}, write) of
		    [] ->
			assigned;
		    [R] ->
			case lists:keymember(Offset, 1, R#chunk.chunks) of
			    true ->
				NC = lists:keydelete(Offset, 1, R#chunk.chunks),
				mnesia:write(R#chunk { chunks = NC }),
				found;
			    false ->
				assigned
			end
		end
	end,
    {atomic, Res} = mnesia:transaction(F),
    Res.

%%--------------------------------------------------------------------
%% Function: remove_chunks/2
%% Args:  Id  ::= integer() - torrent id
%%        Idx ::= integer() - Index of Piece
%% Description: Oblitterate all chunks for Index in the torrent Id.
%%--------------------------------------------------------------------
remove_chunks(_Id, _Idx) ->
    todo.

%%====================================================================
%% Internal functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: find_remaining_chunks(Id, PieceSet) -> [Chunk]
%% Description: Find all remaining chunks for a torrent matching PieceSet
%%--------------------------------------------------------------------
find_remaining_chunks(Id, PieceSet) ->
    MatchHeadAssign = #chunk { idt = {Id, '$1', {assigned, '_'}}, chunks = '$2'},
    MatchHeadNotFetch = #chunk { idt = {Id, '$1', not_fetched}, chunks = '$2'},
    RowsA = mnesia:dirty_select(chunk, [{MatchHeadAssign, [], [{{'$1', '$2'}}]}]),
    RowsN = mnesia:dirty_select(chunk, [{MatchHeadNotFetch, [], [{{'$1', '$2'}}]}]),
    Eligible = [{PN, Chunks} || {PN, Chunks} <- (RowsA ++ RowsN),
				gb_sets:is_element(PN, PieceSet)],
    [{PN, Os, Sz, Ops} || {PN, Chunks} <- Eligible, {Os, Sz, Ops} <- Chunks].


%%--------------------------------------------------------------------
%% Function: chunkify_new_piece(Id, PieceSet) -> ok | none_eligible
%% Description: Find a piece in the PieceSet which has not been chunked
%%  yet and chunk it. Returns either ok if a piece was chunked or none_eligible
%%  if we can't find anything to chunk up in the PieceSet.
%%
%%--------------------------------------------------------------------
chunkify_new_piece(Id, PieceSet) when is_integer(Id) ->
    It = gb_sets:iterator(PieceSet),
    case find_new_piece(Id, It) of
	none ->
	    none_eligible;
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
select_chunks_by_piecenum(Id, PieceNum, Num, Pid) ->
    mnesia:transaction(
      fun () ->
	      case mnesia:read(chunk, {Id, PieceNum, not_fetched}, write) of
		  [] ->
		      %% There are no such chunk anymore. Someone else exhausted it
		      {ok, {PieceNum, []}, Num};
		  [R] ->
		      %% Get up to the number of chunks we want
		      {Return, Rest} = etorrent_utils:gsplit(Num, R#chunk.chunks),
		      [_|_] = Return, % Assert the state of Return
		      %% Write back the missing ones
		      case Rest of
			  [] ->
			      mnesia:delete_object(R);
			  [_|_] ->
			      mnesia:write(R#chunk {chunks = Rest})
		      end,
		      %% Assign chunk to us
		      Q =
			  case mnesia:read(chunk, {Pid, PieceNum, {assigned, Pid}}, write) of
			      [] ->
				  #chunk { idt = {Id, PieceNum, {assigned, Pid}},
					   chunks = [] };
			      [C] when is_record(C, chunk) ->
				  C
			  end,
		      mnesia:write(Q#chunk { chunks = Return ++ Q#chunk.chunks}),
		      %% Return remaining
		      Remaining = Num - length(Return),
		      {ok, {PieceNum, Return}, Remaining}
	      end
      end).

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
%% Function: chunkify_piece(Id, PieceNum) -> {atomic, ok} | {aborted, Reason}
%% Description: Given a PieceNumber, cut it up into chunks and add those
%%   to the chunk table.
%%--------------------------------------------------------------------
chunkify_piece(Id, P) when is_record(P, piece) ->
    Chunks = chunkify(P#piece.files),
    NumChunks = length(Chunks),
    {atomic, Res} =
	mnesia:transaction(
	  fun () ->
		  [S] = mnesia:read({piece, P#piece.idpn}),
		  case S#piece.state of
		  not_fetched ->
			  ok = mnesia:write(S#piece{ state = chunked,
						     left = NumChunks}),
			  ok = mnesia:write(#chunk { idt = {S#piece.id,
							    S#piece.piece_number, not_fetched},
						     chunks = Chunks}),
			  ok;
		  _ ->
			  already_there
		  end
	  end),
    case Res of
	ok ->
	    etorrent_torrent:decrease_not_fetched(Id); % endgames as side-eff.
	already_there ->
	    ok
    end,
    ok.

%%--------------------------------------------------------------------
%% Function: find_new_piece(Id, Iterator) -> #piece | none
%% Description: Search an iterator for a not_fetched piece. Return the #piece
%%   record or none.
%%--------------------------------------------------------------------
find_new_piece(Id, Iterator) ->
    case gb_sets:next(Iterator) of
	{PieceNumber, Next} ->
	    case mnesia:dirty_read(piece, {Id, PieceNumber}) of
		[] ->
		    find_new_piece(Id, Next);
		[P] when P#piece.state =:= not_fetched ->
		    P;
		[_P] ->
		    find_new_piece(Id, Next)
	    end;
	none ->
	    none
    end.

%%--------------------------------------------------------------------
%% Function: find_chunked_chunks(Id, iterator_result()) -> none | PieceNum
%% Description: Search an iterator for a chunked piece.
%%--------------------------------------------------------------------
find_chunked_chunks(_Id, none, Res) ->
    Res;
find_chunked_chunks(Id, {Pn, Next}, Res) ->
    [P] = mnesia:dirty_read(piece, {Id, Pn}),
    case P#piece.state of
	chunked ->
	    case mnesia:dirty_read(chunk, {Id, Pn, not_fetched}) of
		[] ->
		    find_chunked_chunks(Id, gb_sets:next(Next), found_chunked);
		_ ->
		    P#piece.piece_number %% Optimization: Pick the whole piece and pass it on
	    end;
	_Other ->
	    find_chunked_chunks(Id, gb_sets:next(Next), Res)
    end.

