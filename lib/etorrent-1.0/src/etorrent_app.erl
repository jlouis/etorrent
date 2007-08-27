-module(etorrent_app).
-behaviour(application).

-export([start/2, stop/1, start/0]).

start() ->
    application:start(crypto),
    application:start(inets),
    application:start(timer),
    application:start(sasl),
    application:start(etorrent).

start(_Type, _Args) ->
    etorrent_sup:start_link().

stop(_State) ->
    ok.

