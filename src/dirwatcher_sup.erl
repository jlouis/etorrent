-module(dirwatcher_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

start_link(Dir) ->
    supervisor:start_link(dirwatcher_sup, [Dir]).

init(Dir) ->
    {ok, {{one_for_one, 1, 60},
	  [{dirwatcher, {dirwatcher, start_link, [Dir]},
	    permanent, brutal_kill, worker, [dirwatcher]}]}}.

