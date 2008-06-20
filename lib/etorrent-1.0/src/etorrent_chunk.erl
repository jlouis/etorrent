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
-export([add_piece_chunks/2, pick_chunks/4, store_chunk/7,
	 putback_chunks/1]).

%%====================================================================
%% API
%%====================================================================

%%--------------------------------------------------------------------
%% Function: pick_chunks(Handle, PieceSet, StatePid, Num) -> ...
%% Description: Return some chunks for downloading
%%--------------------------------------------------------------------
pick_chunks(Pid, Handle, PieceSet, Num) ->
    pick_chunks(Pid, Handle, PieceSet, [], Num).

pick_chunks(_Pid, _Handle, _PieceSet, SoFar, 0) ->
    {ok, SoFar};
pick_chunks(Pid, Handle, PieceSet, SoFar, N) ->
    case pick_amongst_chunked(Pid, Handle, PieceSet, N) of
	{atomic, {ok, Chunks, PieceNum, 0}} ->
	    {ok, [{PieceNum, Chunks} | SoFar]};
	{atomic, {ok, Chunks, Left, PickedPiece}} when Left > 0 ->
	    pick_chunks(Pid, Handle,
			sets:del_element(PickedPiece,
					 PieceSet),
			[{PickedPiece, Chunks} | SoFar],
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
		      {ok, Chunks, Remaining} =
			  select_chunks_by_piecenum(Handle, PieceNum,
						    N, Pid),
		      {ok, Chunks, Remaining, PieceNum}
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
	      Eligible = qlc:e(Q1, {max_list_size, 1}),
	      case Eligible of
		  [] ->
		      none_eligible;
		  [P] ->
		      ensure_chunking(Id, P),
		      ok
	      end
      end).

find_chunked(Id) when is_integer(Id) ->
    Q = qlc:q([R#piece.piece_number || R <- mnesia:table(piece),
				       R#piece.id =:= Id,
				       R#piece.state =:= chunked]),
    qlc:e(Q).


%%--------------------------------------------------------------------
%% Function: select_chunks_by_piecenum(Id, PieceNum, Num, Pid) ->
%%     {ok, [{Offset, Len}]} | {partial, [{Offset, Len}], Remain}
%% Description: Select up to Num chunks from PieceNum. Will return either
%%  {ok, Chunks} if it got all chunks it wanted, or {partial, Chunks, Remain}
%%  if it got some chunks and there is still Remain chunks left to pick.
%%--------------------------------------------------------------------
select_chunks_by_piecenum(Id, PieceNum, Num, Pid) ->
    %% Pick up to Num chunks
    [R] = mnesia:read(chunk, {Id, PieceNum, not_fetched}, write),
    {Return, Rest} = lists:split(Num, R#chunk.chunks),
    [_|_] = Return, % Assert the state of Return

    %% Explain to the tables we took some chunks
    [Q] = mnesia:read(chunk, {Pid, PieceNum, {assigned, Pid}}, write),
    mnesia:write(Q#chunk { chunks = Q#chunk.chunks ++ Return}),

    %% Based on how much is left, not_fetched, we should update correctly
    case Rest of
	[] ->
	    %% Nothing left, we may not have got everything
	    mnesia:delete_object(R),
	    Remaining = Num - length(Return),
	    {ok, Return, Remaining};
	[_|_] ->
	    %% More left, we got everything we wanted to get
	    mnesia:write(R#chunk {chunks = Rest}),
	    {ok, Return, 0}
    end.

%%--------------------------------------------------------------------
%% Function: putback_chunks(Pid) -> transaction
%% Description: Find all chunks assigned to Pid and mark them as not_fetched
%%--------------------------------------------------------------------
putback_chunks(Pid) ->
    MatchHead = #chunk { idt = {'_', '_', {assigned, Pid}}, _='_'},
    mnesia:transaction(
      fun () ->
	      [Rows] = mnesia:select(chunk, [{MatchHead, [], ['$_']}]),
	      lists:foreach(fun(C) ->
				    {Id, PieceNum, _} = C#chunk.idt,
				    Chunks = C#chunk.chunks,
				    NotFetchIdt = {Id, PieceNum, not_fetched},
				    case mnesia:read(chunk, NotFetchIdt, write) of
					[] ->
					    mnesia:write(#chunk{ idt = NotFetchIdt,
								 chunks = Chunks});
					[R] ->
					    mnesia:write(R#chunk { chunks =
								     R#chunk.chunks ++ Chunks})
				    end
			    end,
			    Rows)
      end).

%%--------------------------------------------------------------------
%% Function: store_chunk(Id, PieceNum, {Offset, Len}, Data, FSPid, PeerGroupPid, Pid) -> ok
%% Description: Workhorse function. Store a chunk in the chunk mnesia table. If we have all
%%    chunks we need, then store the piece on disk.
%%--------------------------------------------------------------------
store_chunk(Id, PieceNum, {Offset, Len}, Data, FSPid, PeerGroupPid, Pid) ->
    {atomic, Res} =
	mnesia:transaction(
	  fun () ->
		  %% Add the newly fetched data to the fetched list
		  case mnesia:read(chunk, {Id, PieceNum, fetched}, write) of
		      [] ->
			  mnesia:write(#chunk { idt = {Id, PieceNum, fetched},
						chunks = [{Offset, Data}]});
		      [R] ->
			  mnesia:write(R#chunk { chunks = [{Offset, Data} | R#chunk.chunks]})
		  end,

		  %% Update that the chunk is not anymore assigned to the Pid
		  [S] = mnesia:read(chunk, {Id, PieceNum, {assigned, Pid}}, write),
		  mnesia:write(S#chunk { chunks = lists:delete({Offset, Len},
							       S#chunk.chunks) }),

		  %% Count down the number of missing chunks for the piece
		  %% XXX: This is expensive! A better piece table should optimize this to
		  %%    a mnesia:read/3
		  Q1 = qlc:q([C || C <- mnesia:table(piece),
				   C#piece.id =:= Id,
				   C#piece.piece_number =:= PieceNum]),
		  [P] = qlc:e(Q1),
		  NewP = P#piece { left = P#piece.left - 1 },
		  mnesia:write(NewP),
		  case NewP#piece.left of
		      0 ->
			  full;
		      N when is_integer(N) ->
			  ok
		  end
	  end),
    case Res of
	full ->
	    store_piece(Id, PieceNum, FSPid, PeerGroupPid);
	ok ->
	    ok
    end.

%%====================================================================
%% Internal functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: invariant_check(PList) -> ok | error
%% Description: Check that a list of chunks for a full piece obeys some
%%   invariants. This piece of code is there mostly as a debugging tool,
%%   but I (jlouis) keep it in to catch some bugs.
%%  TODO: This function needs some work to be correct. The data changed.
%%--------------------------------------------------------------------
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
%% Function: chunkify(PieceSize) ->
%%  {ok, list_of_chunk(), integer()}
%% Description: From a Piece Size designation as an integer, construct
%%   a list of chunks the piece will consist of.
%%--------------------------------------------------------------------
chunkify(PieceSize) ->
    chunkify(?DEFAULT_CHUNK_SIZE, 0, PieceSize, []).

chunkify(_ChunkSize, _Offset, 0, Acc) ->
    {ok, lists:reverse(Acc), length(Acc)};
chunkify(ChunkSize, Offset, Left, Acc)
 when ChunkSize =< Left ->
    chunkify(ChunkSize, Offset+ChunkSize, Left-ChunkSize,
	     [{Offset, ChunkSize} | Acc]);
chunkify(ChunkSize, Offset, Left, Acc) ->
    chunkify(ChunkSize, Offset+Left, 0,
	     [{Offset, Left} | Acc]).

add_piece_chunks(R, PieceSize) ->
    {ok, Chunks, NumChunks} = chunkify(PieceSize),
    mnesia:transaction(
      fun () ->
	      ok = mnesia:write(R#piece{ state = chunked,
					 left = NumChunks}),
	      ok = mnesia:write(#chunk { idt = {R#piece.id, R#piece.piece_number, not_fetched},
					 chunks = Chunks})
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

% XXX: Update to a state 'storing' and check for this when calling here.
%   will avoid a little pesky problem that might occur.
store_piece(Id, PieceNumber, FSPid, MasterPid) ->
    F = fun () ->
		[R] = mnesia:read(chunk, {Id, PieceNumber, fetched}, read),
		mnesia:delete_object(R),
		R#chunk.chunks
	end,
    {atomic, Chunks} = mnesia:transaction(F),
    ok = invariant_check(Chunks),
    Data = list_to_binary(lists:map(fun ({_Offset, Data}) -> Data end,
							  Chunks)),
    DataSize = size(Data),
    case etorrent_fs:write_piece(FSPid,
				 PieceNumber,
				 Data) of
	ok ->
	    {atomic, ok} = etorrent_torrent:statechange(Id,
							{subtract_left, DataSize}),
	    {atomic, ok} = etorrent_torrent:statechange(Id,
							{add_downloaded, DataSize}),
	    ok = etorrent_t_peer_group:broadcast_have(MasterPid, PieceNumber),
	    ok;
	wrong_hash ->
	    %% Piece had wrong hash and its chunks have already been cleaned.
	    %%   set the state to be not_fetched again.
	    {atomic, ok} = etorrent_piece:statechange(Id, PieceNumber, not_fetched),
	    wrong_hash
    end.

