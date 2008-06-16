%%%-------------------------------------------------------------------
%%% File    : etorrent_mnesia_operations.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Various mnesia operations
%%%
%%% Created : 25 Mar 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_mnesia_operations).

-include_lib("stdlib/include/qlc.hrl").
-include("etorrent_mnesia_table.hrl").


%% API
%%% TODO: Consider splitting this code into more parts. Easily done per table.
-export([set_torrent_state/2,
	 select_torrent/1, delete_torrent/1, delete_torrent_by_id/1]).

%%====================================================================
%% API
%%====================================================================

%%--------------------------------------------------------------------
%% Function: set_torrent_state(InfoHash, State) -> ok | not_found
%% Description: Set the state of an info hash.
%%--------------------------------------------------------------------
set_torrent_state(Id, S) when is_integer(Id) ->
    F = fun() ->
		case mnesia:read(torrent, Id, write) of
		    [T] ->
			New = case S of
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

%%--------------------------------------------------------------------
%% Function: select_torrent(Id, Pid) -> Rows
%% Description: Return the torrent identified by Id
%%--------------------------------------------------------------------
select_torrent(Id) ->
    mnesia:dirty_read(torrent, Id).

%%--------------------------------------------------------------------
%% Function: delete_torrent(InfoHash) -> transaction
%% Description: Remove the row with InfoHash in it
%%--------------------------------------------------------------------
delete_torrent(InfoHash) when is_binary(InfoHash) ->
    mnesia:transaction(
      fun () ->
	      case mnesia:read(torrent, infohash, write) of
		  [R] ->
		      {atomic, _} = delete_torrent(R);
		  [] ->
		      ok
	      end
      end);
delete_torrent(Torrent) when is_record(Torrent, torrent) ->
    F = fun() ->
		mnesia:delete_object(Torrent)
	end,
    mnesia:transaction(F).


%%--------------------------------------------------------------------
%% Function: delete_torrent_by_id(id) -> transaction
%% Description: Remove the row with Pid in it
%%--------------------------------------------------------------------
delete_torrent_by_id(Id) ->
    error_logger:info_report([delete_torrent_by_pid, Id]),
    F = fun () ->
		Tr = mnesia:read(torrent, Id),
		mnesia:delete(Tr)
	end,
    mnesia:transaction(F).








%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

