%%%-------------------------------------------------------------------
%%% File    : etorrent.erl
%%% Author  : User Jlouis <jesper.louis.andersen@gmail.com>
%%% License : See COPYING
%%% Description : Start up etorrent and supervise it.
%%%
%%% Created : 30 Jan 2007 by User Jlouis <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------

% TODO: This should be renamed to etorrent_sup
-module(etorrent).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================
start_link() ->
    supervisor:start_link(etorrent, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================
init([]) ->
    InfoHashMap = {info_hash_map,
		   {info_hash_map, start_link, []},
		    permanent, 2000, worker, [info_hash_map]},
    FileAccessMap = {file_access_mapper,
		     {file_access_mapper, start_link, []},
		     permanent, 2000, worker, [file_access_mapper]},
    Listener = {listener,
		{listener, start_link, []},
		permanent, 2000, worker, [listener]},
    Serializer = {serializer,
		  {serializer, start_link, []},
		  permanent, 2000, worker, [serializer]},
    DirWatcherSup = {et_dirwatcher_sup,
		  {et_dirwatcher_sup, start_link, []},
		  transient, infinity, supervisor, [et_dirwatcher_sup]},
    TorrentMgr = {torrent_manager,
		  {torrent_manager, start_link, []},
		  permanent, 2000, worker, [torrent_manager]},
    TorrentPool = {torrent_pool_sup,
		   {torrent_pool_sup, start_link, []},
		   transient, infinity, supervisor, [torrent_pool_sup]},
    {ok, {{one_for_all, 1, 60},
	  [InfoHashMap, FileAccessMap, Listener, Serializer,
	   DirWatcherSup, TorrentMgr, TorrentPool]}}.

%%====================================================================
%% Internal functions
%%====================================================================
