-module(etorrent).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

start_link(Dir) ->
    supervisor:start_link(etorrent, [Dir]).

init(Dir) ->
    {ok, {{one_for_one, 1, 60},
	  [{dirwatcher_sup, {dirwatcher_sup, start_link, [Dir]},
	    permanent, brutal_kill, worker, [dirwatcher_sup]},
	   {torrent_manager_sup, {torrent_manager_sup, start_link, []},
	    permanent, brutal_kill, worker, [torrent_manager_sup]}]}}.
