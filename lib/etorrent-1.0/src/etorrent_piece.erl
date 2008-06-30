%%%-------------------------------------------------------------------
%%% File    : etorrent_pieces.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Operations for manipulating the pieces database table
%%%
%%% Created : 14 Jun 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_piece).

-include_lib("stdlib/include/qlc.hrl").

-include("etorrent_mnesia_table.hrl").

%% API
-export([new/2, statechange/3, is_complete/1,
	 pieces/1, num_not_fetched/1,
	 delete/1, piece/2, piece_valid/2,
	 piece_interesting/2,
	 torrent_size/1, bitfield/1, check_interest/2,
	 store_piece/4]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: new(Id, Dict) -> void()
%% Description: Add a dictionary of pieces to the database.
%%   Dict is a map from PieceNumber -> {Hash, Files, Done} where
%%   Hash is the infohash,
%%   Files is the read operations for this piece,
%%   Done is either 'ok', 'not_ok' or 'none' saying if the piece has
%%   been downloaded already.
%%--------------------------------------------------------------------
new(Id, Dict) when is_integer(Id) ->
    dict:map(fun (PN, {Hash, Files, Done}) ->
		     State = case Done of
				 ok -> fetched;
				 not_ok -> not_fetched;
				 none -> not_fetched
			     end,
		     mnesia:dirty_write(
		       #piece {idpn = {Id, PN},
			       id = Id,
			       piece_number = PN,
			       hash = Hash,
			       files = Files,
			       state = State })
		       end,
		       Dict).

%%--------------------------------------------------------------------
%% Function: delete(Id) -> ok
%% Description: Rip out the pieces identified by torrent with Id
%%--------------------------------------------------------------------
delete(Id) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([P || P <- mnesia:table(piece),
			      P#piece.id =:= Id]),
	      lists:foreach(fun (P) ->
				    mnesia:delete_object(P)
			    end,
			    qlc:e(Q))
      end).

%%--------------------------------------------------------------------
%% Function: statechange(Id, PieceNumber, S) -> ok
%% Description: Update the {Id, PieceNumber} pair to have state S
%%--------------------------------------------------------------------
statechange(Id, Pn, State) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      [R] = mnesia:read(piece, {Id, Pn}, write),
	      mnesia:write(R#piece{state = State})
      end).

%%--------------------------------------------------------------------
%% Function: is_complete(Id) -> bool()
%% Description: Is the torrent identified by Id complete?
%%--------------------------------------------------------------------
is_complete(Id) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([R || R <- mnesia:table(piece),
			      R#piece.id =:= Id,
			      R#piece.state =:= not_fetched]),
	      Objs = qlc:e(Q),
	      length(Objs) =:= 0
      end).

%%--------------------------------------------------------------------
%% Function: pieces(Id) -> [#piece]
%% Description: Return the pieces for Id
%%--------------------------------------------------------------------
pieces(Id) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([R || R <- mnesia:table(piece),
			      R#piece.id =:= Id]),
	      qlc:e(Q)
      end).

%%--------------------------------------------------------------------
%% Function: piece(Id, PieceNumber) -> [#piece]
%% Description: Return the piece PieceNumber for the Id torrent
%%--------------------------------------------------------------------
piece(Id, Pn) when is_integer(Id) ->
    mnesia:dirty_read(piece, {Id, Pn}).

%%--------------------------------------------------------------------
%% Function: piece_valid(Id, PieceNumber) -> bool()
%% Description: Is the piece valid for this torrent?
%%--------------------------------------------------------------------
piece_valid(Id, Pn) when is_integer(Id) ->
    case mnesia:dirty_read(piece, {Id, Pn}) of
	[] ->
	    false;
	[_] ->
	    true
    end.

%%--------------------------------------------------------------------
%% Function: piece_interesting(Id, Pn) -> bool()
%% Description: Is the piece interesting?
%%--------------------------------------------------------------------
piece_interesting(Id, Pn) when is_integer(Id) ->
    [P] = mnesia:dirty_read(piece, {Id, Pn}),
    case P#piece.state of
	fetched ->
	    false;
	chunked ->
	    true;
	not_fetched ->
	    true
    end.

%%--------------------------------------------------------------------
%% Function: bitfield(Id) -> bitfield()
%% Description: Return the bitfield we have for the given torrent
%%--------------------------------------------------------------------
bitfield(Id) when is_integer(Id) ->
    NumPieces = etorrent_torrent:num_pieces(Id),
    {atomic, Fetched}   = fetched(Id),
    etorrent_peer_communication:construct_bitfield(NumPieces,
						   gb_sets:from_list(Fetched)).

%%--------------------------------------------------------------------
%% Function: check_interest(Id, PieceSet) -> interested | not_interested
%% Description: Given a set of pieces, return if we are interested in any of them.
%%--------------------------------------------------------------------
check_interest(Id, PieceSet) when is_integer(Id) ->
    It = gb_sets:iterator(PieceSet),
    find_interest_piece(Id, gb_sets:next(It)).

find_interest_piece(_Id, none) ->
    not_interested;
find_interest_piece(Id, {Pn, Next}) ->
    case mnesia:dirty_read(piece, {Id, Pn}) of
	[] ->
	    invalid_piece;
	[P] when is_record(P, piece) ->
	    case P#piece.state of
		not_fetched ->
		    interested;
		_Other ->
		    find_interest_piece(Id, gb_sets:next(Next))
	    end
    end.

%%--------------------------------------------------------------------
%% Function: torrent_size(Id) -> integer()
%% Description: What is the total size of the torrent in question.
%%--------------------------------------------------------------------
torrent_size(Id) when is_integer(Id) ->
    F = fun () ->
		Query = qlc:q([F || F <- mnesia:table(piece),
				    F#piece.id =:= Id]),
		qlc:e(Query)
	end,
    {atomic, Res} = mnesia:transaction(F),
    lists:foldl(fun(#piece{ files = {_, Ops, _}}, Sum) ->
			Sum + etorrent_fs:size_of_ops(Ops)
		end,
		0,
		Res).

%%--------------------------------------------------------------------
%% Function: store_piece(Id, PieceNumber, FSPid, GroupPid)
%%     -> ok | wrong_hash
%% Description: Store the piece pair {Id, PieceNumber}. Return ok or wrong_hash
%%   in the case that the piece does not Hash-match.
%%
%% Precondition: All chunks for PieceNumber must be downloaded in advance
%%--------------------------------------------------------------------
store_piece(Id, PieceNumber, FSPid, GroupPid) ->
    F = fun () ->
		[R] = mnesia:read(chunk, {Id, PieceNumber, fetched}, read),
		mnesia:delete_object(R),
		R#chunk.chunks
	end,
    {atomic, Offsets} = mnesia:transaction(F),
    Chunks = read_delete_chunks(lists:usort(Offsets), Id, PieceNumber),
    Data = list_to_binary(lists:map(fun ({_Offset, Data}) -> Data end,
				    Chunks)),
    DataSize = size(Data), % Optimization: We can probably check this against #piece.
    case etorrent_fs:write_piece(FSPid,
				 PieceNumber,
				 Data) of
	ok ->
	    {atomic, ok} = etorrent_torrent:statechange(Id,
							{subtract_left, DataSize}),
	    {atomic, ok} = etorrent_torrent:statechange(Id,
							{add_downloaded, DataSize}),
	    {atomic, ok} = statechange(Id, PieceNumber, fetched),
	    ok = etorrent_t_peer_group:broadcast_have(GroupPid, PieceNumber),
	    ok;
	wrong_hash ->
	    %% Piece had wrong hash and its chunks have already been cleaned.
	    %%   set the state to be not_fetched again.
	    {atomic, ok} = etorrent_piece:statechange(Id, PieceNumber, not_fetched),
	    wrong_hash
    end.


%%--------------------------------------------------------------------
%% Function: num_fetched(Id) -> integer()
%% Description: Return the number of not_fetched pieces for torrent Id.
%%--------------------------------------------------------------------
num_not_fetched(Id) when is_integer(Id) ->
    F = fun () ->
		Q = qlc:q([R#piece.piece_number ||
			      R <- mnesia:table(piece),
			      R#piece.id =:= Id,
			      R#piece.state =:= not_fetched]),
		length(qlc:e(Q))
	end,
    {atomic, N} = mnesia:transaction(F),
    N.

%%====================================================================
%% Internal functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: read_delete_chunks(Chunks, Id, PieceNum) -> [{Offset, Chunk}]
%% Description: Read and delete a number of chunks.
%%--------------------------------------------------------------------
read_delete_chunks([], _, _) ->
    [];
read_delete_chunks([Offset | Rest], Id, PieceNum) ->
    %% Read the chunk
    [C] = mnesia:dirty_read(chunk_data, {Id, PieceNum, Offset}),
    %% And delete it
    ok = mnesia:dirty_delete_object(C),
    [{Offset, C#chunk_data.data} | read_delete_chunks(Rest, Id, PieceNum)].


fetched(Id) when is_integer(Id) ->
    F = fun () ->
		Q = qlc:q([R#piece.piece_number ||
			      R <- mnesia:table(piece),
			      R#piece.id =:= Id,
			      R#piece.state =:= fetched]),
		qlc:e(Q)
	end,
    mnesia:transaction(F).
