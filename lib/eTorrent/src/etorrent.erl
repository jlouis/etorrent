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
    Dir = application:get_env(etorrent, dir),
    supervisor:start_link(etorrent, [Dir]).

%%====================================================================
%% Supervisor callbacks
%%====================================================================
init([Dir]) ->
    DirWatcher = {dirwatcher_sup, {dirwatcher_sup, start_link, [Dir]},
		  permanent, 2000, worker, [dirwatcher_sup]},
    TorrentMgr = {torrent_manager_sup, {torrent_manager_sup, start_link, []},
		  permanent, 2000, worker, [torrent_manager_sup]},
    {ok, {{one_for_one, 1, 60},
	  [DirWatcher, TorrentMgr]}}.

%%====================================================================
%% Internal functions
%%====================================================================
