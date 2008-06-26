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
-export([pick_chunks/4, store_chunk/5, putback_chunks/1,
	 endgame_remove_chunk/3]).

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
%% TODO: Needs heavy changes for endgame support.
%%--------------------------------------------------------------------
pick_chunks(Pid, Id, PieceSet, Remaining) ->
    case pick_chunks(pick_chunked, {Pid, Id, PieceSet, [], Remaining}) of
	not_interested ->
	    %% Do the endgame mode handling
	    case etorrent_torrent:is_endgame(Id) of
		false ->
		    %% No endgame yet, just return
		    not_interested;
		true ->
		    pick_chunks(endgame, {Id, PieceSet})
	    end;
	Other ->
	    Other
    end.

%%
%% There are 0 remaining chunks to be desired, return the chunks so far
pick_chunks(_Operation, {_Pid, _Id, _PieceSet, SoFar, 0}) ->
    {ok, SoFar};
%%
%% Pick chunks from the already chunked pieces
pick_chunks(pick_chunked, {Pid, Id, PieceSet, SoFar, Remaining}) ->
    %%% XXX: The following idiom can be substituted with a gb_sets:iterator
    %%%   and optimized to run outside transaction context.
    PieceList = gb_sets:to_list(PieceSet),
    {atomic, Res} =
	mnesia:transaction(
	  fun () ->
		  Q = qlc:q([R#piece.piece_number || R <- mnesia:table(piece),
						     R#piece.id =:= Id,
						     S <- PieceList,
						     R#piece.piece_number =:= S,
						     R#piece.state =:= chunked]),
		  C = qlc:cursor(Q),
		  Rows = qlc:next_answers(C, 1),
		  ok = qlc:delete_cursor(C),
		  Rows
	  end),
    case Res of
	[] ->
	    pick_chunks(chunkify_piece, {Pid, Id, PieceSet, SoFar, Remaining});
	[PieceNum] ->
	    {atomic, {ok, Chunks, Left}} =
		select_chunks_by_piecenum(Id, PieceNum,
					  Remaining, Pid),
	    pick_chunks(pick_chunked, {Pid, Id,
				       gb_sets:del_element(PieceNum, PieceSet),
				       [Chunks | SoFar],
				       Left})
    end;

%%
%% Find a new piece to chunkify. Give up if no more pieces can be chunkified
pick_chunks(chunkify_piece, {Pid, Id, PieceSet, SoFar, Remaining}) ->
    case chunkify_new_piece(Id, PieceSet) of
	ok ->
	    pick_chunks(pick_chunked, {Pid, Id, PieceSet, SoFar, Remaining});
	none_eligible when SoFar =:= [] ->
	    not_interested;
	none_eligible ->
	    {ok, SoFar}
    end;
%%
%% Handle the endgame for a torrent gracefully
pick_chunks(endgame, {Id, PieceSet}) ->
    Remaining = find_remaning_chunks(Id, PieceSet),
    {endgame, etorrent_utils:shuffle(Remaining)}.

%%--------------------------------------------------------------------
%% Function: putback_chunks(Pid) -> transaction
%% Description: Find all chunks assigned to Pid and mark them as not_fetched
%%--------------------------------------------------------------------
putback_chunks(Pid) ->
    MatchHead = #chunk { idt = {'_', '_', {assigned, Pid}}, _='_'},
    mnesia:transaction(
      fun () ->
	      [Rows] = mnesia:select(chunk, [{MatchHead, [], ['$_']}]),
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
			end
		end,
		Rows)
      end).

%%--------------------------------------------------------------------
%% Function: store_chunk(Id, PieceNum, {Offset, Len},
%%                       Data, FSPid, PeerGroupPid, Pid) -> ok
%% Description: Workhorse function. Store a chunk in the chunk mnesia table.
%%    If we have all chunks we need, then store the piece on disk.
%%--------------------------------------------------------------------
store_chunk(Id, PieceNum, {Offset, Len}, Data, Pid) ->
    {atomic, Res} =
	mnesia:transaction(
	  fun () ->
		  %% Add the newly fetched data to the fetched list and add the
		  %%   data itself to the #chunk_data table.
		  DataState =
		      case mnesia:dirty_read(chunk_data, {Id, PieceNum, Offset}) of
			  [] ->
			      mnesia:write(#chunk_data { idt = {Id, PieceNum, Offset},
							 data = Data }),
			      ok;
			  [_] ->
			      already_downloaded
		      end,
		  case mnesia:read(chunk, {Id, PieceNum, fetched}, write) of
		      [] ->
			  mnesia:write(#chunk { idt = {Id, PieceNum, fetched},
						chunks = [Offset]});
		      [R] ->
			  mnesia:write(
			    R#chunk { chunks =
				      [Offset | R#chunk.chunks]})
		  end,
		  %% Update that the chunk is not anymore assigned to the Pid
		  [S] = mnesia:read(chunk,
				    {Id, PieceNum, {assigned, Pid}},
				    write),
		  case lists:delete({Offset, Len}, S#chunk.chunks) of
		      [] ->
			  mnesia:delete_object(S);
		      L when is_list(L) ->
			  mnesia:write(S#chunk { chunks = L })
		  end,
		  %% Count down the number of missing chunks for the piece
		  %% Next lines can be thrown into a seperate counter for speed.
		  case DataState of
		      ok ->
			  [P] = mnesia:read(piece, {Id, PieceNum}, write),
			  NewP = P#piece { left = P#piece.left - 1 },
			  mnesia:write(NewP),
			  case NewP#piece.left of
			      0 ->
				  full;
			      N when is_integer(N) ->
				  ok
			  end;
		      already_downloaded ->
			  ok
		  end
	  end),
    Res.

endgame_remove_chunk(Pid, Id, {Index, Offset, Len}) ->
    [R] = mnesia:dirty_read(chunk, {Id, Index, {assigned, Pid}}),
    NC = lists:delete({Index, Offset, Len}, R#chunk.chunks),
    mnesia:dirty_write(R#chunk {chunks = NC}).

%%====================================================================
%% Internal functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: find_remaining_chunks(Id, PieceSet) -> [Chunk]
%% Description: Find all remaining chunks for a torrent matching PieceSet
%%--------------------------------------------------------------------
find_remaning_chunks(Id, PieceSet) ->
    MatchHead = #chunk { idt = {Id, '$1', {assigned, '_'}}, chunks = '$2'},
    F = fun () ->
		mnesia:select(chunk, [{MatchHead, [], [{'$1', '$2'}]}])
	end,
    {atomic, Rows} = mnesia:transaction(F),

    Res = lists:foldl(fun ({PN, Chunks}, Accum) ->
			      case gb_sets:is_element(PN, PieceSet) of
				  true ->
				      NewChunks = lists:map(fun ({Os, Sz}) ->
								    {PN, Os, Sz}
							    end,
							    Chunks),
				      NewChunks ++ Accum;
				  false ->
				      Accum
			      end
		      end,
		      [],
		      Rows),
    {endgame, Res}.

%%--------------------------------------------------------------------
%% Function: chunkify_new_piece(Id, PieceSet) -> ok | none_eligible
%% Description: Find a piece in the PieceSet which has not been chunked
%%  yet and chunk it. Returns either ok if a piece was chunked or none_eligible
%%  if we can't find anything to chunk up in the PieceSet.
%%
%% TODO: Optimization possible: return the piece number we chunked up,
%%   so pick_chunks/2 can shortcut the selection.
%%--------------------------------------------------------------------
chunkify_new_piece(Id, PieceSet) when is_integer(Id) ->
    % XXX: This can be run outside transaction context
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
		      mnesia:write(Q#chunk { chunks = Q#chunk.chunks ++ Return}),
		      %% Return remaining
		      Remaining = Num - length(Return),
		      {ok, {PieceNum, Return}, Remaining}
	      end
      end).

%%--------------------------------------------------------------------
%% Function: chunkify(PieceSize) ->
%%  {ok, list_of_chunk(), integer()}
%% Description: From a Piece Size designation as an integer, construct
%%   a list of chunks the piece will consist of.
%%--------------------------------------------------------------------
chunkify(PieceSize) ->
    chunkify(?DEFAULT_CHUNK_SIZE, 0, PieceSize, []).

chunkify(_ChunkSize, _Offset, 0, Acc) ->
    {ok, lists:reverse(Acc), length(Acc)};

chunkify(ChunkSize, Offset, Left, Acc) when ChunkSize =< Left ->
    chunkify(ChunkSize, Offset+ChunkSize, Left-ChunkSize,
	     [{Offset, ChunkSize} | Acc]);

chunkify(ChunkSize, Offset, Left, Acc) ->
    chunkify(ChunkSize, Offset+Left, 0,
	     [{Offset, Left} | Acc]).


%%--------------------------------------------------------------------
%% Function: chunkify_piece(Id, PieceNum) -> {atomic, ok} | {aborted, Reason}
%% Description: Given a PieceNumber, cut it up into chunks and add those
%%   to the chunk table.
%%--------------------------------------------------------------------
chunkify_piece(Id, P) when is_record(P, piece) ->
    {ok, Chunks, NumChunks} = chunkify(etorrent_fs:size_of_ops(P#piece.files)),
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
