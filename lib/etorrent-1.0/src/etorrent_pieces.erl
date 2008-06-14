%%%-------------------------------------------------------------------
%%% File    : etorrent_pieces.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Operations for manipulating the pieces database table
%%%
%%% Created : 14 Jun 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_pieces).

-include_lib("stdlib/include/qlc.hrl").

-include("etorrent_mnesia_table.hrl").

%% API
-export([new/2, set_state/3, is_complete/1,
	 get_pieces/1, delete/1, get_piece/2, piece_valid/2,
	 piece_interesting/2]).

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
		       #piece {id = Id,
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
	      mnesia:delete(file_access, Id, write)
      end).

%%--------------------------------------------------------------------
%% Function: set_state(Id, PieceNumber, S) -> ok
%% Description: Update the {Id, PieceNumber} pair to have state S
%%--------------------------------------------------------------------
set_state(Id, Pn, State) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([R || R <- mnesia:table(file_access),
			      R#piece.id =:= Id,
			      R#piece.piece_number =:= Pn]),
	      [Row] = qlc:e(Q),
	      mnesia:write(Row#piece{state = State})
      end).

%%--------------------------------------------------------------------
%% Function: is_complete(Id) -> bool()
%% Description: Is the torrent identified by Id complete?
%%--------------------------------------------------------------------
is_complete(Id) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([R || R <- mnesia:table(file_access),
			      R#piece.id =:= Id,
			      R#piece.state =:= not_fetched]),
	      Objs = qlc:e(Q),
	      length(Objs) =:= 0
      end).

%%--------------------------------------------------------------------
%% Function: get_pieces(Id) -> [#piece]
%% Description: Return the pieces for Id
%%--------------------------------------------------------------------
get_pieces(Id) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([R || R <- mnesia:table(file_access),
			      R#piece.id =:= Id]),
	      qlc:e(Q)
      end).

%%--------------------------------------------------------------------
%% Function: get_piece(Id, PieceNumber) -> [#piece]
%% Description: Return the piece PieceNumber for the Id torrent
%%--------------------------------------------------------------------
get_piece(Id, Pn) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([R || R <- mnesia:table(file_access),
			      R#piece.id =:= Id,
			      R#piece.piece_number =:= Pn]),
	      qlc:e(Q)
      end).

%%--------------------------------------------------------------------
%% Function: piece_valid(Id, PieceNumber) -> bool()
%% Description: Is the piece valid for this torrent?
%%--------------------------------------------------------------------
piece_valid(Id, Pn) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([R || R <- mnesia:table(file_access),
			      R#piece.id =:= Id,
			      R#piece.piece_number =:= Pn]),
	      case qlc:e(Q) of
		  [] ->
		      false;
		  [_] ->
		      true
	      end
      end).

%%--------------------------------------------------------------------
%% Function: piece_interesting(Id, Pn) -> bool()
%% Description: Is the piece interesting?
%%--------------------------------------------------------------------
piece_interesting(Id, Pn) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([R || R <- mnesia:table(file_access),
			      R#piece.id =:= Id,
			      R#piece.piece_number =:= Pn]),
	      [R] = qlc:e(Q),
	      case R#piece.state of
		  fetched ->
		      false;
		  chunked ->
		      true;
		  not_fetched ->
		      true
	      end
      end).

%%====================================================================
%% Internal functions
%%====================================================================
