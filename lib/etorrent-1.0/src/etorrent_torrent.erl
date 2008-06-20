%%%-------------------------------------------------------------------
%%% File    : etorrent_torrent.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Library for manipulating the torrent table.
%%%
%%% Created : 15 Jun 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_torrent).

-include_lib("stdlib/include/qlc.hrl").
-include("etorrent_mnesia_table.hrl").

%% API
-export([new/3, delete/1, get_by_id/1, statechange/2,
	 get_num_pieces/1, downloaded_piece/1]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: new(Id, LoadData, NPieces) -> NPieces
%% Description: Initialize a torrent entry for Id with the tracker
%%   state as given. Pieces is the number of pieces for this torrent.
%%--------------------------------------------------------------------
new(Id, {{uploaded, U}, {downloaded, D}, {left, L}}, NPieces) ->
    F = fun() ->
		mnesia:write(#torrent { id = Id,
					left = L,
					uploaded = U,
					downloaded = D,
					pieces = NPieces,
					state = unknown })
	end,
    mnesia:transaction(F),
    mnesia:dirty_update_counter(torrent, Id, NPieces).

%%--------------------------------------------------------------------
%% Function: delete(Id) -> transaction
%% Description: Remove the torrent identified by Id. Id is either a
%%   an integer, or the Record itself we want to remove.
%%--------------------------------------------------------------------
delete(Id) when is_integer(Id) ->
    [R] = mnesia:dirty_read(torrent, Id),
    delete(R);
delete(Torrent) when is_record(Torrent, torrent) ->
    F = fun() ->
		mnesia:delete_object(Torrent)
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function: get_by_id(Id, Pid) -> Rows
%% Description: Return the torrent identified by Id
%%--------------------------------------------------------------------
get_by_id(Id) ->
    mnesia:dirty_read(torrent, Id).

%%--------------------------------------------------------------------
%% Function: get_num_pieces(Id) -> integer()
%% Description: Return the number of pieces for torrent Id
%%--------------------------------------------------------------------
get_num_pieces(Id) ->
    [R] = mnesia:dirty_read(torrent, Id),
    R#torrent.pieces.


%%--------------------------------------------------------------------
%% Function: downloaded_piece(Id) -> ok | endgame
%% Description: track that we downloaded a piece, eventually updating
%%  the endgame result.
%%--------------------------------------------------------------------
downloaded_piece(Id) ->
    N = mnesia:dirty_update_counter(torrent, Id, -1),
    case N of
	0 ->
	    statechange(Id, endgame),
	    endgame;
	N when is_integer(N) ->
	    ok
    end.

%%--------------------------------------------------------------------
%% Function: statechange(InfoHash, State) -> ok | not_found
%% Description: Set the state of an info hash.
%%--------------------------------------------------------------------
statechange(Id, What) when is_integer(Id) ->
    F = fun() ->
		case mnesia:read(torrent, Id, write) of
		    [T] ->
			New = case What of
				  unknown ->
				      T#torrent{state = unknown};
				  leeching ->
				      T#torrent{state = leeching};
				  seeding ->
				      T#torrent{state = seeding};
				  endgame ->
				      T#torrent{state = endgame};
				  {add_downloaded, Amount} ->
				      T#torrent{downloaded = T#torrent.downloaded + Amount};
				  {add_upload, Amount} ->
				      T#torrent{uploaded = T#torrent.uploaded + Amount};
				  {subtract_left, Amount} ->
				      T#torrent{left = T#torrent.left - Amount};
				  {tracker_report, Seeders, Leechers} ->
				      T#torrent{seeders = Seeders, leechers = Leechers}
			      end,
			mnesia:write(New),
			ok;
		    [] ->
			not_found
		end
	end,
    mnesia:transaction(F).

%%====================================================================
%% Internal functions
%%====================================================================
