-module(torrent_manager_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

start_link(Dir) ->
    supervisor:start_link(torrent_manager_sup, [Dir]).

init(Dir) ->
    {ok, {{one_for_one, 1, 60},
	  [{torrent_manager, {torrent_manager, start_link, [Dir]},
	    permanent, brutal_kill, worker, [torrent_manager]}]}}.

