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
		    {etorrent_event_mgr, start_link, []},
		    permanent, 2000, worker, [etorrent_event_mgr]},
    FastResume = {fast_resume,
		  {etorrent_fast_resume, start_link, []},
		  permanent, 5000, worker, [etorrent_fast_resume]},
    Listener = {listener,
		{etorrent_listener, start_link, []},
		permanent, 2000, worker, [etorrent_listener]},
    AcceptorSup = {acceptor_sup,
		   {etorrent_acceptor_sup, start_link, []},
		   permanent, infinity, supervisor, [etorrent_acceptor_sup]},
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
	  [EventManager, Listener, AcceptorSup,
	   DirWatcherSup, TorrentMgr, TorrentPool, FastResume]}}.

%%====================================================================
%% Internal functions
%%====================================================================
