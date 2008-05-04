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
-export([add_piece_chunks/2, pick_chunks/4, store_chunk/4,
	 putback_chunks/2, select_chunk/4]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: select_chunk(Handle, Index, Offset, Len) -> {atomic, Ref}
%% Description: Select the ref of a chunk.
%%--------------------------------------------------------------------
select_chunk(Handle, Idx, Offset, Size) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([R#chunk.ref || R <- mnesia:table(chunk),
					R#chunk.piece_number =:= Idx,
					R#chunk.offset =:= Offset,
					R#chunk.size =:= Size,
					R#chunk.pid =:= Handle]),
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

chunkify_new_piece(Handle, PieceSet) ->
    mnesia:transaction(
      fun () ->
	      Q1 = qlc:q([S || R <- mnesia:table(file_access),
			       S <- sets:to_list(PieceSet),
			       R#file_access.pid =:= Handle,
			       R#file_access.piece_number =:= S,
			       R#file_access.state =:= not_fetched]),
	      Eligible = qlc:e(Q1),
	      case Eligible of
		  [] ->
		      none_eligible;
		  L when is_list(L) ->
		      case etorrent_mnesia_histogram:find_rarest_piece(
			     Handle,
			     sets:from_list(L)) of
			  {atomic, {ok, PieceNum}} ->
			      ensure_chunking(Handle, PieceNum),
			      ok
		      end
	      end
      end).

find_chunked(Handle) ->
    Q = qlc:q([R#file_access.piece_number || R <- mnesia:table(file_access),
					     R#file_access.pid =:= Handle,
					     R#file_access.state =:= chunked]),
    qlc:e(Q).


select_chunks_by_piecenum(Handle, PieceNum, Num, Pid) ->
    Q = qlc:q([R || R <- mnesia:table(chunk),
		    R#chunk.pid =:= Handle,
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
%% Function: add_piece_chunks(#file_access, PieceSize) -> ok.
%% Description: Add chunks for a piece of a given torrent.
%%--------------------------------------------------------------------
add_piece_chunks(R, PieceSize) ->
    {ok, Chunks, NumChunks} = chunkify(R#file_access.piece_number, PieceSize),
    mnesia:transaction(
      fun () ->
	      ok = mnesia:write(R#file_access{ state = chunked,
					       left = NumChunks}),
	      add_chunk(Chunks, R#file_access.pid)
      end).

store_chunk(Ref, Data, FSPid, MasterPid) ->
    {atomic, Res} =
	mnesia:transaction(
	  fun () ->
		  [R] = mnesia:read(chunk, Ref, write),
		  Pid = R#chunk.pid,
		  PieceNum = R#chunk.piece_number,
		  mnesia:write(chunk, R#chunk { state = fetched,
						assign = Data },
			       write),
		  Q1 = qlc:q([C || C <- mnesia:table(file_access),
				   C#file_access.pid =:= Pid,
				   C#file_access.piece_number =:= PieceNum]),
		  [P] = qlc:e(Q1),
		  NewP = P#file_access { left = P#file_access.left - 1 },
		  mnesia:write(NewP),
		  case NewP#file_access.left of
		      0 ->
			  {full, Pid, R#chunk.piece_number};
		      N when is_integer(N) ->
			  ok
		  end
      end),
    case Res of
	{full, Pid, PieceNum} ->
	    store_piece(Pid, PieceNum, FSPid, MasterPid),
	    ok;
	ok ->
	    ok
    end.

%%====================================================================
%% Internal functions
%%====================================================================

%%% XXX: This function ought to do something more.
putback_piece(Pid, PieceNumber) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([C || C <- mnesia:table(chunk),
			      C#chunk.pid =:= Pid,
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

ensure_chunking(Handle, PieceNum) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([S || S <- mnesia:table(file_access),
			      S#file_access.pid =:= Handle,
			      S#file_access.piece_number =:= PieceNum]),
	      [R] = qlc:e(Q),
	      case R#file_access.state of
		  not_fetched ->
		      add_piece_chunks(R, etorrent_fs:size_of_ops(R#file_access.files)),
		      Q1 = qlc:q([T || T <- mnesia:table(file_access),
				       T#file_access.pid =:= Handle,
				       T#file_access.state =:= not_fetched]),
		      case length(qlc:e(Q1)) of
			  0 ->
			      {atomic, _} = etorrent_mnesia_operations:set_torrent_state(Handle, endgame),
			      ok;
			  N when is_integer(N) ->
			      ok
		      end
	          % If we get 'fetched' here it is an error.
	      end
      end).

add_chunk([], _) ->
    ok;
add_chunk([{PieceNumber, Offset, Size} | Rest], Pid) ->
    ok = mnesia:write(#chunk{ ref = make_ref(),
			      pid = Pid,
			      piece_number = PieceNumber,
			      offset = Offset,
			      size = Size,
			      assign = unknown,
			      state = not_fetched}),
    add_chunk(Rest, Pid).


% XXX: Update to a state 'storing' and check for this when calling here.
%   will avoid a little pesky problem that might occur.
store_piece(ControlPid, PieceNumber, FSPid, MasterPid) ->
    F = fun () ->
		Q = qlc:q([{Cs#chunk.offset,
			    Cs#chunk.size,
			    Cs#chunk.state,
			    Cs#chunk.assign}
			   || Cs <- mnesia:table(chunk),
			      Cs#chunk.pid =:= ControlPid,
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
	    {atomic, ok} = etorrent_mnesia_operations:set_torrent_state(ControlPid,
									{subtract_left, DataSize}),
	    {atomic, _} =
		etorrent_mnesia_operations:set_torrent_state(ControlPid,
							     {add_downloaded, DataSize}),
	    ok = etorrent_t_peer_group:broadcast_have(MasterPid, PieceNumber),
	    ok;
	wrong_hash ->
	    putback_piece(ControlPid, PieceNumber),
	    wrong_hash
    end.


