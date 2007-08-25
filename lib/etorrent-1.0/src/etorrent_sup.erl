%%%-------------------------------------------------------------------
%%% File    : etorrent.erl
%%% Author  : User Jlouis <jesper.louis.andersen@gmail.com>
%%% License : See COPYING
%%% Description : Start up etorrent and supervise it.
%%%
%%% Created : 30 Jan 2007 by User Jlouis <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_sup).

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
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================
init([]) ->
    EventManager = {event_manager,
		    {etorrent_event, start_link, []},
		    permanent, 2000, worker, [etorrent_event]},
    InfoHashMap = {torrent_mapper,
		   {etorrent_t_mapper, start_link, []},
		    permanent, 2000, worker, [etorrent_t_mapper]},
    FileAccessMap = {fs_mapper,
		     {etorrent_fs_mapper, start_link, []},
		     permanent, 2000, worker, [etorrent_fs_mapper]},
    Listener = {listener,
		{etorrent_listener, start_link, []},
		permanent, 2000, worker, [etorrent_listener]},
    Serializer = {fs_serializer,
		  {etorrent_fs_serializer, start_link, []},
		  permanent, 2000, worker, [etorrent_fs_serializer]},
    DirWatcherSup = {dirwatcher_sup,
		  {etorrent_dirwatcher_sup, start_link, []},
		  transient, infinity, supervisor, [etorrent_dirwatcher_sup]},
    TorrentMgr = {manager,
		  {etorrent_t_manager, start_link, []},
		  permanent, 2000, worker, [etorrent_t_manager]},
    TorrentPool = {torrent_pool_sup,
		   {etorrent_t_pool_sup, start_link, []},
		   transient, infinity, supervisor, [etorrent_t_pool_sup]},
    {ok, {{one_for_all, 1, 60},
	  [EventManager, InfoHashMap, FileAccessMap, Listener,
	   Serializer, DirWatcherSup, TorrentMgr, TorrentPool]}}.

%%====================================================================
%% Internal functions
%%====================================================================
