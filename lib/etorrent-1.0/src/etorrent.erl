-module(etorrent).
-behaviour(application).

-include("etorrent_mnesia_table.hrl").

-export([db_initialize/0]).
-export([start/2, stop/1, start/0]).
-export([help/0, list/0]).

start() ->
    dbg:tracer(),
    application:start(crypto),
    application:start(inets),
    application:start(timer),
    application:start(sasl),
    timer:start(),
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

%%--------------------------------------------------------------------
%% Function: list() -> io()
%% Description: List currently active torrents.
%%--------------------------------------------------------------------
list() ->
    {atomic, A} = etorrent_torrent:get_all(),
    lists:foreach(fun (R) ->
			  io:format("Id: ~p ~p total ~p left ~f% ~n",
				    [R#torrent.id,
				     R#torrent.total,
				     R#torrent.left,
				     percent_complete(R)])
		  end, A).

%%--------------------------------------------------------------------
%% Function: help() -> io()
%% Description: Provide a simple help message for the commands supported.
%%--------------------------------------------------------------------
help() ->
    implement_me_please.

%% --------------------------------------------------------------------
%% Internal functions
%% --------------------------------------------------------------------
percent_complete(R) ->
    %% left / complete * 100 = % done
    (R#torrent.total - R#torrent.left) / R#torrent.total * 100.

