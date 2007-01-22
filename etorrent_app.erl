-module(etorrent_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, [Dir]) ->
    etorrent:start_link(Dir).

stop(_State) ->
    ok.

