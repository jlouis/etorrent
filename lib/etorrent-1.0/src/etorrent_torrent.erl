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
-export([new/3, delete/1, get_by_id/1, get_all/0, statechange/2,
	 get_num_pieces/1, decrease_not_fetched/1,
	 is_endgame/1, get_mode/1]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: new(Id, LoadData, NPieces) -> NPieces
%% Description: Initialize a torrent entry for Id with the tracker
%%   state as given. Pieces is the number of pieces for this torrent.
%% Precondition: The #piece table has been filled with the torrents pieces.
%%--------------------------------------------------------------------
new(Id, {{uploaded, U}, {downloaded, D}, {left, L}, {total, T}}, NPieces) ->
    F = fun() ->
		State = case L of 0 -> seeding; _ -> leeching end,
		mnesia:write(#torrent { id = Id,
					left = L,
					total = T,
					uploaded = U,
					downloaded = D,
					pieces = NPieces,
					state = State })
	end,
    {atomic, _} = mnesia:transaction(F),
    Missing = etorrent_piece:get_num_not_fetched(Id),
    mnesia:dirty_update_counter(torrent_c_pieces, Id, Missing).

%%--------------------------------------------------------------------
%% Function: get_mode(Id) -> seeding | endgame | leeching
%% Description: Return the current mode of the torrent.
%%--------------------------------------------------------------------
get_mode(Id) ->
    [#torrent { state = S}] = mnesia:dirty_read(torrent, Id),
    S.

%%--------------------------------------------------------------------
%% Function: delete(Id) -> transaction
%% Description: Remove the torrent identified by Id. Id is either a
%%   an integer, or the Record itself we want to remove.
%%--------------------------------------------------------------------
delete(Id) when is_integer(Id) ->
    [R] = mnesia:dirty_read(torrent, Id),
    delete(R);
delete(Torrent) when is_record(Torrent, torrent) ->
    mnesia:dirty_delete(torrent_c_pieces, Torrent#torrent.id),
    mnesia:dirty_delete_object(Torrent).

%%--------------------------------------------------------------------
%% Function: get_by_id(Id, Pid) -> Rows
%% Description: Return the torrent identified by Id
%%--------------------------------------------------------------------
get_by_id(Id) ->
    mnesia:dirty_read(torrent, Id).

%%--------------------------------------------------------------------
%% Function: get_all() -> Rows
%% Description: Return all torrents, sorted by Id
%%--------------------------------------------------------------------
get_all() ->
    get_all(#torrent.id).

%%--------------------------------------------------------------------
%% Function: get_all(Pos) -> Rows
%% Description: Return all torrents, sorted by Pos
%%--------------------------------------------------------------------
get_all(Pos) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([P || P <- mnesia:table(torrent)]),
	      qlc:e(qlc:keysort(Pos, Q))
      end).


%%--------------------------------------------------------------------
%% Function: get_num_pieces(Id) -> integer()
%% Description: Return the number of pieces for torrent Id
%%--------------------------------------------------------------------
get_num_pieces(Id) ->
    [R] = mnesia:dirty_read(torrent, Id),
    R#torrent.pieces.


%%--------------------------------------------------------------------
%% Function: decrease_not_fetched(Id) -> ok | endgame
%% Description: track that we downloaded a piece, eventually updating
%%  the endgame result.
%%--------------------------------------------------------------------
decrease_not_fetched(Id) ->
    N = mnesia:dirty_update_counter(torrent_c_pieces, Id, -1),
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
				      Left = T#torrent.left - Amount,
				      case Left of
					  0 ->
					      T#torrent { left = 0, state = seeding };
					  N when is_integer(N) ->
					      T#torrent { left = N }
				      end;
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

%%--------------------------------------------------------------------
%% Function: is_endgame(Id) -> bool()
%% Description: Returns true if the torrent is in endgame mode
%%--------------------------------------------------------------------
is_endgame(Id) ->
    [T] = mnesia:dirty_read(torrent, Id),
    T#torrent.state =:= endgame.

%%====================================================================
%% Internal functions
%%====================================================================
