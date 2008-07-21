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
-export([new/3, delete/1, select/1, all/0, statechange/2,
	 num_pieces/1, decrease_not_fetched/1,
	 is_endgame/1, mode/1]).

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
    State = case L of
		0 ->
		    etorrent_event_mgr:seeding_torrent(Id),
		    seeding;
		_ -> leeching
	    end,
    F = fun() ->
		mnesia:write(#torrent { id = Id,
					left = L,
					total = T,
					uploaded = U,
					downloaded = D,
					pieces = NPieces,
					state = State })
	end,
    {atomic, _} = mnesia:transaction(F),
    Missing = etorrent_piece_mgr:num_not_fetched(Id),
    mnesia:dirty_update_counter(torrent_c_pieces, Id, Missing),
    ok.

%%--------------------------------------------------------------------
%% Function: mode(Id) -> seeding | endgame | leeching
%% Description: Return the current mode of the torrent.
%%--------------------------------------------------------------------
mode(Id) ->
    [#torrent { state = S}] = mnesia:dirty_read(torrent, Id),
    S.

%%--------------------------------------------------------------------
%% Function: delete(Id) -> transaction
%% Description: Remove the torrent identified by Id. Id is either a
%%   an integer, or the Record itself we want to remove.
%%--------------------------------------------------------------------
delete(Id) when is_integer(Id) ->
    mnesia:dirty_delete(torrent, Id),
    mnesia:dirty_delete(torrent_c_pieces, Id).

%%--------------------------------------------------------------------
%% Function: select(Id, Pid) -> Rows
%% Description: Return the torrent identified by Id
%%--------------------------------------------------------------------
select(Id) ->
    mnesia:dirty_read(torrent, Id).

%%--------------------------------------------------------------------
%% Function: all() -> Rows
%% Description: Return all torrents, sorted by Id
%%--------------------------------------------------------------------
all() ->
    all(#torrent.id).

%%--------------------------------------------------------------------
%% Function: all(Pos) -> Rows
%% Description: Return all torrents, sorted by Pos
%%--------------------------------------------------------------------
all(Pos) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([P || P <- mnesia:table(torrent)]),
	      qlc:e(qlc:keysort(Pos, Q))
      end).


%%--------------------------------------------------------------------
%% Function: num_pieces(Id) -> integer()
%% Description: Return the number of pieces for torrent Id
%%--------------------------------------------------------------------
num_pieces(Id) ->
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
statechange(_Id, []) ->
    ok;
statechange(Id, [What | Rest]) ->
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
					  N when N =< T#torrent.total ->
					      T#torrent { left = N }
				      end;
				  {tracker_report, Seeders, Leechers} ->
				      T#torrent{seeders = Seeders, leechers = Leechers}
			      end,
			mnesia:write(New),
			{T#torrent.state, New#torrent.state}
		end
	end,
    {atomic, Res} = mnesia:transaction(F),
    case Res of
	{leeching, seeding} ->
	    etorrent_event_mgr:seeding_torrent(Id),
	    ok;
	_ ->
	    ok
    end,
    statechange(Id, Rest);
statechange(Id, What) when is_integer(Id) ->
    statechange(Id, [What]).

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
