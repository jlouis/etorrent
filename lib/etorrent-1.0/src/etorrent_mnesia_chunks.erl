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
-export([add_piece_chunks/2, select_chunks/5, store_chunk/6,
	 putback_chunks/2, select_chunk/4]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: 
%% Description:
%%--------------------------------------------------------------------

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
select_chunks(Pid, Handle, PieceSet, StatePid, Num) ->
    case piece_chunk_available(Handle, PieceSet, Num, Pid) of
	{atomic, {ok, Chunks}} ->
	    {ok, Chunks};
	{atomic, none_applicable} ->
	    select_new_piece_for_chunking(Pid, Handle, PieceSet, StatePid, Num)
    end.

find_chunked(Handle) ->
    Q = qlc:q([R#file_access.piece_number || R <- mnesia:table(file_access),
					     R#file_access.pid =:= Handle,
					     R#file_access.state =:= chunked]),
    qlc:e(Q).

piece_chunk_available(Handle, PieceSet, Num, Pid) ->
    mnesia:transaction(
      fun () ->
	      Chunked = find_chunked(Handle),
	      case sets:intersection(PieceSet, sets:from_list(Chunked)) of
		  [] ->
		      none_applicable;
		  [PieceNum | _] ->
		      Chunks = select_chunk_by_piecenum(Handle, PieceNum, Num, Pid),
		      {ok, Chunks}
	      end
      end).

select_chunk_by_piecenum(Handle, PieceNum, Num, Pid) ->
    Q = qlc:q([R || R <- mnesia:table(chunk),
		    R#chunk.pid =:= Handle,
		    R#chunk.piece_number =:= PieceNum,
		    R#chunk.state =:= not_fetched]),
    QC = qlc:cursor(Q),
    Ans = qlc:next_answers(QC, Num),
    ok = qlc:delete_cursor(QC),
    {atomic, _} = assign_chunk_to_pid(Ans, Pid),
    Ans.

select_new_piece_for_chunking(Pid, Handle, PieceSet, StatePid, Num) ->
    case etorrent_t_state:request_new_piece(StatePid, PieceSet) of
	not_interested ->
	    not_interested;
	endgame ->
	    mnesia:transaction(
	      fun () ->
		      Q1 = qlc:q([R || R <- mnesia:table(chunk),
				       R#chunk.pid =:= Handle,
				       (R#chunk.state =:= assigned)
					   or (R#chunk.state =:= not_fetched)]),
		      shuffle(qlc:e(Q1))
	      end);
	{ok, PieceNum, Size} ->
	    {atomic, _} = mnesia:transaction(
			    fun () ->
				    {atomic, _} = ensure_chunking(Handle, PieceNum, StatePid, Size)
			    end),
	    select_chunks(Pid, Handle, PieceSet, StatePid, Num)
    end.

%%--------------------------------------------------------------------
%% Function: add_piece_chunks(PieceNum, PieceSize, Torrent) -> ok.
%% Description: Add chunks for a piece of a given torrent.
%%--------------------------------------------------------------------
putback_chunks(Refs, Pid) ->
    mnesia:transaction(
      fun () ->
	      lists:foreach(fun(Ref) ->
				    Row = mnesia:read(chunk, Ref, write),
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

add_piece_chunks(R, PieceSize) ->
    {ok, Chunks, NumChunks} = chunkify(R#file_access.piece_number, PieceSize),
    mnesia:transaction(
      fun () ->
	      ok = mnesia:write(R#file_access{ state = chunked,
					       left = NumChunks}),
	      add_chunk(Chunks, R#file_access.pid)
      end).

store_chunk(Ref, Data, PieceNumber, StatePid, FSPid, MasterPid) ->
    mnesia:transaction(
      fun () ->
	      error_logger:info_report([reading, Ref]),
	      [R] = mnesia:read(chunk, Ref, write),
	      Pid = R#chunk.pid,
	      mnesia:write(R#chunk { state = fetched,
				     assign = Data }),
	      Q = qlc:q([S || S <- mnesia:table(file_access),
			      S#file_access.pid =:= Pid,
			      S#file_access.piece_number =:= PieceNumber]),
	      [P] = qlc:e(Q),
	      mnesia:write(P#file_access { left = P#file_access.left - 1 }),
	      check_for_full_piece(Pid, R#chunk.piece_number, StatePid, FSPid, MasterPid),
	      ok
      end).

check_for_full_piece(Pid, PieceNumber, StatePid, FSPid, MasterPid) ->
    mnesia:transaction(
      fun () ->
	      R = mnesia:read(file_access, Pid, read),
	      case R#file_access.left of
		  0 ->
		      store_piece(Pid, PieceNumber, StatePid, FSPid, MasterPid);
		  N when is_integer(N) ->
		      ok
	      end
      end).

store_piece(Pid, PieceNumber, StatePid, FSPid, MasterPid) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([{Cs#chunk.offset,
			  Cs#chunk.size,
			  Cs#chunk.state,
			  Cs#chunk.assign}
			   || Cs <- mnesia:table(chunk),
					    Cs#chunk.pid =:= Pid,
					    Cs#chunk.piece_number =:= PieceNumber,
					    Cs#chunk.state =:= fetched]),
	      Q2 = qlc:keysort(1, Q),
	      Q3 = qlc:q([D || {_Offset, _Size, _State, D} <- Q2]),
	      Piece = qlc:e(Q3),
	      ok = invariant_check(qlc:e(Q2)),
	      case etorrent_fs:write_piece(FSPid,
					   PieceNumber,
					   list_to_binary(Piece)) of
		  ok ->
		      ok = etorrent_t_state:got_piece_from_peer(
			     StatePid, PieceNumber,
			     lists:foldl(fun({_, S, _, _}, Acc) ->
						 S + Acc
					 end,
					 0,
					 Piece)),
		      ok = etorrent_t_peer_group:got_piece_from_peer(
			     MasterPid, PieceNumber),
		      ok;
		  wrong_hash ->
		      putback_piece(Pid, PieceNumber),
		      wrong_hash
	      end
      end).

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

ensure_chunking(Handle, PieceNum, StatePid, Size) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([S || S <- mnesia:table(file_access),
			      S#file_access.pid =:= Handle,
			      S#file_access.piece_number =:= PieceNum]),
	      [R] = qlc:e(Q),
	      case R#file_access.state of
		  chunked ->
		      ok;
		  not_fetched ->
		      add_piece_chunks(R, Size),
		      Q1 = qlc:q([T || T <- mnesia:table(file_access),
				       T#file_access.pid =:= Handle,
				       T#file_access.state =:= not_fetched]),
		      case length(qlc:e(Q1)) of
			  0 ->
			      etorrent_t_state:endgame(StatePid),
			      ok;
			  N when is_integer(N) ->
			      ok
		      end
	          % If we get 'fetched' here it is an error.
	      end
      end).

% XXX: Come up with a better shuffle function.
shuffle(X) ->
    X.
