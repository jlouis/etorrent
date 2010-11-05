-module(etorrent_app).
-behaviour(application).

-include("etorrent_version.hrl").

-export([start/2, stop/1, prep_stop/1]).


-ignore_xref([{'prep_stop', 1}, {stop, 0}, {check, 1}]).

-define(RANDOM_MAX_SIZE, 999999999999).

%% @doc Application callback.
%% @end
start(_Type, _Args) ->
    PeerId = generate_peer_id(),
    %% DB
    etorrent_mnesia_init:init(),
    etorrent_mnesia_init:wait(),
    etorrent_sup:start_link(PeerId).

%% @doc Application callback.
%% @end
prep_stop(_S) ->
    io:format("Shutting down etorrent~n"),
    ok.

%% @doc Application callback.
%% @end
stop(_State) ->
    ok.

%% @doc Generate a random peer id for use
%% @end
generate_peer_id() ->
    Number = crypto:rand_uniform(0, ?RANDOM_MAX_SIZE),
    Rand = io_lib:fwrite("~B----------", [Number]),
    lists:flatten(io_lib:format("-ET~s-~12s", [?VERSION, Rand])).
