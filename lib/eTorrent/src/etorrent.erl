%%%-------------------------------------------------------------------
%%% File    : etorrent.erl
%%% Author  : User Jlouis <jlouis@succubus.localdomain>
%%% Description : Start up etorrent and supervise it.
%%%
%%% Created : 30 Jan 2007 by User Jlouis <jlouis@succubus.localdomain>
%%%-------------------------------------------------------------------
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
    RandomSourceSup = {random_source_sup,
		       {random_source_sup, start_link, []},
		       permanent, infinity, supervisor, [random_source_sup]},
    Serializer = {serializer,
		  {serializer, start_link, []},
		  permanent, 2000, worker, [serializer]},
    DirWatcherSup = {dirwatcher_sup,
		  {dirwatcher_sup, start_link, []},
		  permanent, infinity, supervisor, [dirwatcher]},
    TorrentMgr = {torrent_manager,
		  {torrent_manager, start_link, []},
		  permanent, 2000, worker, [torrent_manager]},
    {ok, {{one_for_all, 1, 60},
	  [RandomSourceSup, Serializer, DirWatcherSup, TorrentMgr]}}.

%%====================================================================
%% Internal functions
%%====================================================================
