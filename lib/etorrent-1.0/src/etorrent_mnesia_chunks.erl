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
-export([add_piece_chunks/3, select_chunks/5]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: 
%% Description:
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: select_chunks(Handle, PieceSet, StatePid, Num) -> ...
%% Description: Return some chunks for downloading
%%--------------------------------------------------------------------
select_chunks(Pid, Handle, PieceSet, StatePid, Num) ->
    case etorrent_t_state:request_new_piece(StatePid, PieceSet) of
	not_interested ->
	    not_interested;
	{ok, PieceNum} ->
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
add_piece_chunks(PieceNum, PieceSize, Torrent) ->
    {ok, Chunks, _} = chunkify(PieceNum, PieceSize),
    mnesia:transaction(
      fun () ->
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

%%====================================================================
%% Internal functions
%%====================================================================

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
						 R#chunk{state = {assigned_to, Pid}},
						 write)
			    end,
			    Ans)
      end).
