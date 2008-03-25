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
-export([new_torrent/2, find_torrents_by_file/1, cleanup_torrent_by_pid/1]).

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
							  T#tracking_map.supervisor_pid == Pid]),
		lists:foreach(fun (F) -> mnesia:delete(tracking_map, F, write) end, qlc:e(Query))
	end,
    mnesia:transaction(F).
