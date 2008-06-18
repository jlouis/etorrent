%%%-------------------------------------------------------------------
%%% File    : etorrent_mnesia_chunks.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Chunking code for mnesia.
%%%
%%% Created : 31 Mar 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_mnesia_chunks).

-include_lib("stdlib/include/qlc.hrl").

-include("etorrent_mnesia_table.hrl").

-define(DEFAULT_CHUNK_SIZE, 16384). % Default size for a chunk. All clients use this.

%% API
-export([add_piece_chunks/2, pick_chunks/4, store_chunk/5,
	 putback_chunks/2, select_chunk/4]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: select_chunk(Handle, Index, Offset, Len) -> {atomic, Ref}
%% Description: Select the ref of a chunk.
%%--------------------------------------------------------------------
select_chunk(Id, Idx, Offset, Size) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([R#chunk.ref || R <- mnesia:table(chunk),
					R#chunk.piece_number =:= Idx,
					R#chunk.offset =:= Offset,
					R#chunk.size =:= Size,
					R#chunk.id =:= Id]),
	      qlc:e(Q)
      end).

%%--------------------------------------------------------------------
%% Function: select_chunks(Handle, PieceSet, StatePid, Num) -> ...
%% Description: Return some chunks for downloading
%%--------------------------------------------------------------------
pick_chunks(Pid, Handle, PieceSet, Num) ->
    pick_chunks(Pid, Handle, PieceSet, [], Num).

pick_chunks(_Pid, _Handle, _PieceSet, SoFar, 0) ->
    {ok, SoFar};
pick_chunks(Pid, Handle, PieceSet, SoFar, N) ->
    case pick_amongst_chunked(Pid, Handle, PieceSet, N) of
	{atomic, {ok, Chunks, 0}} ->
	    {ok, SoFar ++ Chunks};
	{atomic, {ok, Chunks, Left, PickedPiece}} when Left > 0 ->
	    pick_chunks(Pid, Handle,
			sets:del_element(PickedPiece,
					 PieceSet),
			SoFar ++ Chunks,
			Left);
	{atomic, none_eligible} ->
	    case chunkify_new_piece(Handle, PieceSet) of
		{atomic, ok} ->
		    pick_chunks(Pid,
				Handle,
				PieceSet,
				SoFar,
				N);
		{atomic, none_eligible} ->
		    case SoFar of
			[] ->
			    not_interested;
			L when is_list(L) ->
			    {partial, L, N}
		    end
	    end
    end.

pick_amongst_chunked(Pid, Handle, PieceSet, N) ->
    mnesia:transaction(
      fun () ->
	      ChunkedPieces = find_chunked(Handle),
	      Eligible = sets:to_list(sets:intersection(PieceSet, sets:from_list(ChunkedPieces))),
	      case Eligible of
		  [] ->
		      none_eligible;
		  [PieceNum | _] ->
		      case select_chunks_by_piecenum(Handle, PieceNum,
						     N, Pid) of
			  {ok, Ans} ->
			      {ok, Ans, 0};
			  {partial, Chunks, Remaining, PieceNum} ->
			      {ok, Chunks, Remaining, PieceNum}
		      end
	      end
      end).

chunkify_new_piece(Id, PieceSet) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q1 = qlc:q([S || R <- mnesia:table(piece),
			       S <- sets:to_list(PieceSet),
			       R#piece.id =:= Id,
			       R#piece.piece_number =:= S,
			       R#piece.state =:= not_fetched]),
	      Eligible = qlc:e(Q1),
	      case Eligible of
		  [] ->
		      none_eligible;
		  [P | _] ->
		      ensure_chunking(Id, P),
		      ok
	      end
      end).

find_chunked(Id) when is_integer(Id) ->
    Q = qlc:q([R#piece.piece_number || R <- mnesia:table(piece),
					     R#piece.id =:= Id,
					     R#piece.state =:= chunked]),
    qlc:e(Q).


select_chunks_by_piecenum(Id, PieceNum, Num, Pid) ->
    Q = qlc:q([R || R <- mnesia:table(chunk),
		    R#chunk.id =:= Id,
		    R#chunk.piece_number =:= PieceNum,
		    R#chunk.state =:= not_fetched]),
    QC = qlc:cursor(Q),
    Ans = qlc:next_answers(QC, Num),
    ok = qlc:delete_cursor(QC),
    {atomic, _} = assign_chunk_to_pid(Ans, Pid),
    case length(Ans) of
	Num ->
	    {ok, Ans};
	N when is_integer(N) ->
	    Remaining = Num - N,
	    {partial, Ans, Remaining, PieceNum}
    end.

%%--------------------------------------------------------------------
%% Function: add_piece_chunks(PieceNum, PieceSize, Torrent) -> ok.
%% Description: Add chunks for a piece of a given torrent.
%%--------------------------------------------------------------------
putback_chunks(Refs, Pid) ->
    mnesia:transaction(
      fun () ->
	      lists:foreach(fun(Ref) ->
				    [Row] = mnesia:read(chunk, Ref, write),
				    case Row#chunk.state of
					fetched ->
					    ok;
					not_fetched ->
					    ok;
					assigned when Row#chunk.assign == Pid ->
					    mnesia:write(chunk, Row#chunk{ state = not_fetched,
									   assign = unknown },
							 write)
				    end
			    end,
			    Refs)
      end).

%%--------------------------------------------------------------------
%% Function: add_piece_chunks(#piece, PieceSize) -> ok.
%% Description: Add chunks for a piece of a given torrent.
%%--------------------------------------------------------------------
add_piece_chunks(R, PieceSize) ->
    {ok, Chunks, NumChunks} = chunkify(R#piece.piece_number, PieceSize),
    mnesia:transaction(
      fun () ->
	      ok = mnesia:write(R#piece{ state = chunked,
					       left = NumChunks}),
	      add_chunk(Chunks, R#piece.id)
      end).

store_chunk(Ref, Data, FSPid, MasterPid, Id) ->
    {atomic, Res} =
	mnesia:transaction(
	  fun () ->
		  [R] = mnesia:read(chunk, Ref, write),
		  Id = R#chunk.id,
		  PieceNum = R#chunk.piece_number,
		  mnesia:write(chunk, R#chunk { state = fetched,
						assign = Data },
			       write),
		  Q1 = qlc:q([C || C <- mnesia:table(piece),
				   C#piece.id =:= Id,
				   C#piece.piece_number =:= PieceNum]),
		  [P] = qlc:e(Q1),
		  NewP = P#piece { left = P#piece.left - 1 },
		  mnesia:write(NewP),
		  case NewP#piece.left of
		      0 ->
			  {full, Id, R#chunk.piece_number};
		      N when is_integer(N) ->
			  ok
		  end
      end),
    case Res of
	{full, Pid, PieceNum} ->
	    store_piece(Pid, PieceNum, FSPid, MasterPid, Id),
	    ok;
	ok ->
	    ok
    end.

%%====================================================================
%% Internal functions
%%====================================================================

%%% XXX: This function ought to do something more.
putback_piece(Id, PieceNumber) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([C || C <- mnesia:table(chunk),
			      C#chunk.id =:= Id,
			      C#chunk.piece_number =:= PieceNumber]),
	      Rows = qlc:e(Q),
	      lists:foreach(fun(Row) ->
				    mnesia:write(Row#chunk { state = not_fetched,
							     assign = unknown })
			    end,
			    Rows)
      end).

invariant_check(PList) ->
    V = lists:foldl(fun (_T, error) -> error;
			({Offset, _Size, fetched, _D}, N) when Offset /= N ->
			    error;
			({_Offset, Size, fetched, Data}, _N) when Size /= size(Data) ->
			    error;
			({Offset, Size, fetched, _Data}, N) when Offset == N ->
			    Offset + Size
		    end,
		    0,
		    PList),
    case V of
	error ->
	    error;
	N when is_integer(N) ->
	    ok
    end.

%%--------------------------------------------------------------------
%% Function: chunkify(integer(), integer()) ->
%%  {ok, list_of_chunk(), integer()}
%% Description: From a Piece number and its total size this function
%%  builds the chunks the piece consist of.
%%--------------------------------------------------------------------
chunkify(PieceNum, PieceSize) ->
    chunkify(?DEFAULT_CHUNK_SIZE, 0, PieceNum, PieceSize, []).

chunkify(_ChunkSize, _Offset, _PieceNum, 0, Acc) ->
    {ok, lists:reverse(Acc), length(Acc)};
chunkify(ChunkSize, Offset, PieceNum, Left, Acc)
 when ChunkSize =< Left ->
    chunkify(ChunkSize, Offset+ChunkSize, PieceNum, Left-ChunkSize,
	     [{PieceNum, Offset, ChunkSize} | Acc]);
chunkify(ChunkSize, Offset, PieceNum, Left, Acc) ->
    chunkify(ChunkSize, Offset+Left, PieceNum, 0,
	     [{PieceNum, Offset, Left} | Acc]).

assign_chunk_to_pid(Ans, Pid) ->
    mnesia:transaction(
      fun () ->
	      lists:foreach(fun(R) ->
				    mnesia:write(chunk,
						 R#chunk{state = assigned,
							 assign = Pid},
						 write)
			    end,
			    Ans)
      end).

ensure_chunking(Id, PieceNum) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([S || S <- mnesia:table(piece),
			      S#piece.id =:= Id,
			      S#piece.piece_number =:= PieceNum]),
	      [R] = qlc:e(Q),
	      case R#piece.state of
		  not_fetched ->
		      add_piece_chunks(R, etorrent_fs:size_of_ops(R#piece.files)),
		      Q1 = qlc:q([T || T <- mnesia:table(piece),
				       T#piece.id =:= Id,
				       T#piece.state =:= not_fetched]),
		      case length(qlc:e(Q1)) of
			  0 ->
			      {atomic, _} =
				  etorrent_torrent:statechange(Id, endgame),
			      ok;
			  N when is_integer(N) ->
			      ok
		      end
	          % If we get 'fetched' here it is an error.
	      end
      end).

add_chunk([], _) ->
    ok;
add_chunk([{PieceNumber, Offset, Size} | Rest], Id) when is_integer(Id) ->
    ok = mnesia:write(#chunk{ ref = make_ref(),
			      id = Id,
			      piece_number = PieceNumber,
			      offset = Offset,
			      size = Size,
			      assign = unknown,
			      state = not_fetched}),
    add_chunk(Rest, Id).


% XXX: Update to a state 'storing' and check for this when calling here.
%   will avoid a little pesky problem that might occur.
store_piece(Ref, PieceNumber, FSPid, MasterPid, Id) ->
    F = fun () ->
		Q = qlc:q([{Cs#chunk.offset,
			    Cs#chunk.size,
			    Cs#chunk.state,
			    Cs#chunk.assign}
			   || Cs <- mnesia:table(chunk),
			      Cs#chunk.ref =:= Ref,
			      Cs#chunk.piece_number =:= PieceNumber,
			      Cs#chunk.state =:= fetched]),
		Q2 = qlc:keysort(1, Q),
		Q3 = qlc:q([D || {_, _, _, D} <- Q]),
	      Piece = qlc:e(Q3),
	      Invariant = qlc:e(Q2),
	      {Piece, Invariant}
      end,
    {atomic, {Piece, Invariant}} = mnesia:transaction(F),
    ok = invariant_check(Invariant),
    case etorrent_fs:write_piece(FSPid,
				 PieceNumber,
				 list_to_binary(Piece)) of
	ok ->
	    DataSize = lists:foldl(fun({_, S, _, _}, Acc) -> S + Acc end,
				   0,
				   Invariant),
	    {atomic, ok} = etorrent_torrent:statechange(Id,
							{subtract_left, DataSize}),
	    {atomic, _} = etorrent_torrent:statechange(Id,
						       {add_downloaded, DataSize}),
	    ok = etorrent_t_peer_group:broadcast_have(MasterPid, PieceNumber),
	    ok;
	wrong_hash ->
	    putback_piece(Id, PieceNumber),
	    wrong_hash
    end.


