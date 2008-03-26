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
-export([new_torrent/2, find_torrents_by_file/1, cleanup_torrent_by_pid/1,
	 store_info_hash/3, set_info_hash_state/2, select_info_hash/2,
	 select_info_hash/1, delete_info_hash/1, delete_info_hash_by_pid/1]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: new_torrent(Filename, Supervisor) -> ok
%% Description: Add a new torrent given by File with the Supervisor
%%   pid as given to the database structure.
%%--------------------------------------------------------------------
new_torrent(File, Supervisor) ->
    T = fun () ->
		mnesia:write(#tracking_map { filename = File,
					     supervisor_pid = Supervisor })
	end,
    mnesia:transaction(T).

%%--------------------------------------------------------------------
%% Function: find_torrents_by_file(Filename) -> [SupervisorPid]
%% Description: Find torrent specs matching the filename in question.
%%--------------------------------------------------------------------
find_torrents_by_file(Filename) ->
    Query = qlc:q([T#tracking_map.filename || T <- mnesia:table(tracking_map),
					      T#tracking_map.filename == Filename]),
    qlc:e(Query).

%%--------------------------------------------------------------------
%% Function: cleanup_torrent_by_pid(Pid) -> ok
%% Description: Clean out all references to torrents matching Pid
%%--------------------------------------------------------------------
cleanup_torrent_by_pid(Pid) ->
    F = fun() ->
		Query = qlc:q([T#tracking_map.filename || T <- mnesia:table(tracking_map),
							  T#tracking_map.supervisor_pid =:= Pid]),
		lists:foreach(fun (F) -> mnesia:delete(tracking_map, F, write) end, qlc:e(Query))
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function: store_info_hash(InfoHash, StorerPid, MonitorRef) -> transaction
%% Description: Store that InfoHash is controlled by StorerPid with assigned
%%  monitor reference MonitorRef
%%--------------------------------------------------------------------
store_info_hash(InfoHash, StorerPid, MonitorRef) ->
    F = fun() ->
		mnesia:write(#info_hash { info_hash = InfoHash,
					  storer_pid = StorerPid,
					  monitor_reference = MonitorRef,
					  state = unknown })
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function: set_info_hash_state(InfoHash, State) -> ok | not_found
%% Description: Set the state of an info hash.
%%--------------------------------------------------------------------
set_info_hash_state(InfoHash, State) ->
    F = fun() ->
		case mnesia:read(info_hash, InfoHash, write) of
		    [IH] ->
			New = IH#info_hash{state = State},
			mnesia:write(New),
			ok;
		    [] ->
			not_found
		end
	end,
    {atomic, Res} = mnesia:transaction(F),
    Res.

%%--------------------------------------------------------------------
%% Function: select_info_hash_pids(InfoHash, Pid) -> Rows
%% Description: Return rows matching infohash and pid
%%--------------------------------------------------------------------
select_info_hash(InfoHash, Pid) ->
    Q = qlc:q([IH || IH <- mnesia:table(info_hash),
		     IH#info_hash.info_hash =:= InfoHash,
		     IH#info_hash.storer_pid =:= Pid]),
    qlc:e(Q).

%%--------------------------------------------------------------------
%% Function: select_info_hash_pids(InfoHash) -> Pids
%% Description: Return all rows matching infohash
%%--------------------------------------------------------------------
select_info_hash(InfoHash) ->
    Q = qlc:q([IH || IH <- mnesia:table(info_hash),
		     IH#info_hash.info_hash =:= InfoHash]),
    qlc:e(Q).

%%--------------------------------------------------------------------
%% Function: delete_info_hash(InfoHash) -> transaction
%% Description: Remove the row with InfoHash in it
%%--------------------------------------------------------------------
delete_info_hash(InfoHash) ->
    F = fun() ->
		mnesia:delete(info_hash, InfoHash, write)
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function: delete_info_hash_by_pid(Pid) -> transaction
%% Description: Remove the row with Pid in it
%%--------------------------------------------------------------------
delete_info_hash_by_pid(Pid) ->
    F = fun() ->
		Q = qlc:q([IH#info_hash.info_hash || IH <- mnesia:table(info_hash),
						     IH#info_hash.storer_pid =:= Pid]),
		lists:foreach(fun (H) ->
				      mnesia:delete(info_hash, H, write)
			      end,
			      qlc:e(Q))
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function: create_peer_info() -> transaction
%% Description: Create a new peer_info object and return a unique ref
%%  to it in the transaction.
%%--------------------------------------------------------------------
create_peer_info() ->
    F = fun() ->
		Ref = make_ref(),
		mnesia:write(#peer_info { id = Ref,
					  uploaded = 0,
					  downloaded = 0,
					  interested = false,
					  remote_choking = true,
					  optimistic_unchoke = false}),
		Ref
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------


