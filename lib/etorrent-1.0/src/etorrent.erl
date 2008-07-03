-module(etorrent).
-behaviour(application).

-include("etorrent_mnesia_table.hrl").

-export([db_initialize/0, stop/0, start/0]).
-export([start/2, stop/1]).
-export([help/0, list/0]).

start() ->
    dbg:tracer(),
    application:start(crypto),
    application:start(inets),
    application:start(timer),
    application:start(sasl),
    mnesia:start(),
    db_initialize(),
    application:start(etorrent).


start(_Type, _Args) ->
    etorrent_sup:start_link().

stop() ->
    application:stop(etorrent),
    halt().

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
    {atomic, A} = etorrent_torrent:all(),
    io:format("~3s ~11s ~11s ~11s ~11s ~3s ~3s ~7s~n",
	      ["Id:", "total", "left", "uploaded", "downloaded",
	       "I", "C", "Comp."]),
    lists:foreach(fun (R) ->
			  io:format("~3.B ~11.B ~11.B ~11.B ~11.B ~3.B ~3.B ~7.3f% ~n",
				    [R#torrent.id,
				     R#torrent.total,
				     R#torrent.left,
				     R#torrent.uploaded,
				     R#torrent.downloaded,
				     R#torrent.leechers,
				     R#torrent.seeders,
				     percent_complete(R)])
		  end, A).

%%--------------------------------------------------------------------
%% Function: help() -> io()
%% Description: Provide a simple help message for the commands supported.
%%--------------------------------------------------------------------
help() ->
    io:format("Available commands:~n", []),

    Commands = [{"list", "List torrents in system"},
	        {"stop", "Stop the system"}],

    lists:foreach(fun({Command, Desc}) ->
			  io:format("~-12.s - ~s~n", [Command, Desc])
		  end,
		  Commands),
    ok.

%% --------------------------------------------------------------------
%% Internal functions
%% --------------------------------------------------------------------
percent_complete(R) ->
    %% left / complete * 100 = % done
    (R#torrent.total - R#torrent.left) / R#torrent.total * 100.

