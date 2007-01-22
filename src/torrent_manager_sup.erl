-module(torrent_manager_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link(torrent_manager_sup, []).

init(_Dir) ->
    {ok, {{one_for_one, 1, 60},
	  [{torrent_manager, {torrent_manager, start_link, []},
	    permanent, brutal_kill, worker, [torrent_manager]}]}}.

