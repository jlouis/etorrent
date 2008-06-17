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
-export([new/2, delete/1, statechange/2]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: 
%% Description:
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: new(Id, LoadData) -> transaction
%% Description: Initialyze a torrent entry for Id with the tracker
%%   state as given.
%%--------------------------------------------------------------------
new(Id, {{uploaded, U}, {downloaded, D}, {left, L}}) ->
    F = fun() ->
		mnesia:write(#torrent { id = Id,
					left = L,
					uploaded = U,
					downloaded = D,
					state = unknown })
	end,
    mnesia:transaction(F).

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
