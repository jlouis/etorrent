%%%-------------------------------------------------------------------
%%% File    : etorrent.erl
%%% Author  : User Jlouis <jlouis@succubus.localdomain>
%%% Description : 
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
%%--------------------------------------------------------------------
%% Func: init(Args) -> {ok,  {SupFlags,  [ChildSpec]}} |
%%                     ignore                          |
%%                     {error, Reason}
%% Description: Whenever a supervisor is started using 
%% supervisor:start_link/[2,3], this function is called by the new process 
%% to find out about restart strategy, maximum restart frequency and child 
%% specifications.
%%--------------------------------------------------------------------
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
