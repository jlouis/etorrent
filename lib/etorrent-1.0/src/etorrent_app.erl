-module(etorrent_app).
-behaviour(application).

-export([db_initialize/0]).
-export([start/2, stop/1, start/0]).

-define(DEBUG, on).

start() ->
    dbg:tracer(),
    application:start(crypto),
    application:start(inets),
    application:start(timer),
    application:start(sasl),
    timer:start(), % TODO: Set as a kernel parameter
    mnesia:start(),
    db_initialize(),
    application:start(etorrent).


start(_Type, _Args) ->
    etorrent_sup:start_link().

stop(_State) ->
    ok.

db_initialize() ->
    mnesia:create_schema([node()]),
    etorrent_mnesia_init:init().

