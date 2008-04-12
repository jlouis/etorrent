-module(etorrent_app).
-behaviour(application).

-export([db_initialize/0]).
-export([start/2, stop/1, start/0, reload/0]).

start() ->
    application:start(crypto),
    application:start(inets),
    application:start(timer),
    application:start(sasl),
    mnesia:start(),
    application:start(etorrent).

start(_Type, _Args) ->
    etorrent_sup:start_link().

stop(_State) ->
    ok.

db_initialize() ->
    mnesia:create_schema([node()]),
    mnesia:start(),
    etorrent_mnesia_init:init(),
    mnesia:stop().

purge_rl(X) ->
    code:purge(X),
    code:load_file(X).

reload() ->
    purge_rl(etorrent_dirwatcher),
    purge_rl(etorrent_t_manager),
    purge_rl(etorrent_mnesia_operations).



