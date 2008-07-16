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
-export([new/2, statechange/3, complete/1,
	 select/1, select/2, num_not_fetched/1,
	 delete/1, valid/2, interesting/2,
	 bitfield/1, check_interest/2]).

-export([t_fetched/2]).

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
%% Function: complete(Id) -> bool()
%% Description: Is the torrent identified by Id complete?
%%--------------------------------------------------------------------
complete(Id) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([R || R <- mnesia:table(piece),
			      R#piece.id =:= Id,
			      R#piece.state =:= not_fetched]),
	      Objs = qlc:e(Q),
	      length(Objs) =:= 0
      end).

%%--------------------------------------------------------------------
%% Function: select(Id) -> [#piece]
%% Description: Return the pieces for Id
%%--------------------------------------------------------------------
select(Id) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([R || R <- mnesia:table(piece),
			      R#piece.id =:= Id]),
	      qlc:e(Q)
      end).

%%--------------------------------------------------------------------
%% Function: select(Id, PieceNumber) -> [#piece]
%% Description: Return the piece PieceNumber for the Id torrent
%%--------------------------------------------------------------------
select(Id, Pn) when is_integer(Id) ->
    mnesia:dirty_read(piece, {Id, Pn}).

%%--------------------------------------------------------------------
%% Function: valid(Id, PieceNumber) -> bool()
%% Description: Is the piece valid for this torrent?
%%--------------------------------------------------------------------
valid(Id, Pn) when is_integer(Id) ->
    case mnesia:dirty_read(piece, {Id, Pn}) of
	[] ->
	    false;
	[_] ->
	    true
    end.

%%--------------------------------------------------------------------
%% Function: interesting(Id, Pn) -> bool()
%% Description: Is the piece interesting?
%%--------------------------------------------------------------------
interesting(Id, Pn) when is_integer(Id) ->
    [P] = mnesia:dirty_read(piece, {Id, Pn}),
    case P#piece.state of
	fetched ->
	    false;
	_ ->
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
%% Function: check_interest(Id, PieceSet) -> interested | not_interested | invalid_piece
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
		fetched ->
		    find_interest_piece(Id, gb_sets:next(Next));
		_Other ->
		    interested
	    end
    end.

%%--------------------------------------------------------------------
%% Function: t_fetched/2
%% Args:     Id ::= integer() - torrent id
%%           PieceNum ::= integer() - piece index.
%% Description: predicate. True if piece is fetched.
%%--------------------------------------------------------------------
t_fetched(Id, PieceNum) ->
    [P] = mnesia:read(piece, {Id, PieceNum}, read),
    P#piece.state =:= fetched.

%%--------------------------------------------------------------------
%% Function: num_not_fetched(Id) -> integer()
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
fetched(Id) when is_integer(Id) ->
    F = fun () ->
		[_] = mnesia:read(torrent, Id, read),
		Q = qlc:q([R#piece.piece_number ||
			      R <- mnesia:table(piece),
			      R#piece.id =:= Id,
			      R#piece.state =:= fetched]),
		qlc:e(Q)
	end,
    mnesia:transaction(F).
