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
    RandomSource = {random_source, {random_source, start_link, []},
		    permanent, brutal_kill, worker, [random_source]},
    DirWatcher = {dirwatcher, {dirwatcher, start_link, []},
		  permanent, 2000, worker, [dirwatcher]},
    TorrentMgr = {torrent_manager, {torrent_manager, start_link, []},
		  permanent, 2000, worker, [torrent_manager]},
    {ok, {{one_for_one, 1, 60},
	  [RandomSource, DirWatcher, TorrentMgr]}}.

%%====================================================================
%% Internal functions
%%====================================================================
