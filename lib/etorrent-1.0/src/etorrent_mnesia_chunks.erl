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
-export([add_piece_chunks/3, select_chunks/5, store_chunk/5,
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
    case etorrent_t_state:request_new_piece(StatePid, PieceSet) of
	not_interested ->
	    not_interested;
	endgame ->
	    mnesia:transaction(
	      fun () ->
		      Q1 = qlc:q([R || R <- mnesia:table(chunks),
				      R#chunk.pid =:= Handle,
				      R#chunk.state =:= assigned]),
		      Q2 = qlc:q([R || R <- mnesia:table(chunks),
				       R#chunk.pid =:= Handle,
				       R#chunk.state =:= not_fetched]),
		      shuffle(qlc:e(qlc:append(Q1, Q2)))
	      end);
	{ok, PieceNum, Size} ->
	    {atomic, ok} = ensure_chunking(Handle, PieceNum, StatePid, Size),
	    mnesia:transaction(
	      fun () ->
		      Q = qlc:q([R || R <- mnesia:table(chunks),
				      R#chunk.pid =:= Handle,
				      R#chunk.piece_number =:= PieceNum,
				      R#chunk.state =:= not_fetched]),
		      QC = qlc:cursor(Q),
		      Ans = qlc:next_answers(QC, Num),
		      assign_chunk_to_pid(Ans, Pid),
		      Ans
	      end)
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
%% Function: add_piece_chunks(PieceNum, PieceSize, Torrent) -> ok.
%% Description: Add chunks for a piece of a given torrent.
%%--------------------------------------------------------------------
add_piece_chunks(PieceNum, PieceSize, Torrent) ->
    {ok, Chunks, NumChunks} = chunkify(PieceNum, PieceSize),
    mnesia:transaction(
      fun () ->
	      R = mnesia:read(file_access, Torrent, write),
	      {atomic, _} = mnesia:write(file_access,
					 R#file_access{ state = chunked,
							left = NumChunks},
					 write),
	      lists:foreach(fun({PN, Offset, Size}) ->
				    mnesia:write(chunks,
						 #chunk{ ref = make_ref(),
							 pid = Torrent,
							 piece_number = PN,
							 offset = Offset,
							 size = Size,
							 state = unfetched},
						 write)
			    end,
			    Chunks)
      end).

store_chunk(Ref, Data, StatePid, FSPid, MasterPid) ->
    mnesia:transaction(
      fun () ->
	      R = mnesia:read(chunk, Ref, write),
	      Pid = R#chunk.pid,
	      mnesia:write(chunk, R#chunk { state = fetched,
					    assign = Data },
			   write),
	      P = mnesia:read(file_access, Pid, write),
	      mnesia:write(file_access,
			   P#file_access { left = P#file_access.left - 1 },
			   write),
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
			   || Cs <- mnesia:table(chunks),
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
	      Q = qlc:q([C || C <- mnesia:table(chunks),
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
		      add_piece_chunks(PieceNum, Size, Handle),
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
