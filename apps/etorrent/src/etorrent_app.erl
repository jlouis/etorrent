-module(etorrent_app).
-behaviour(application).

-include("etorrent_version.hrl").

-export([stop/0, start/0]).
-export([start/2, stop/1, prep_stop/1]).


-ignore_xref([{'prep_stop', 1}, {stop, 0}, {check, 1}]).

-define(RANDOM_MAX_SIZE, 999999999999).

%% @doc Start up the etorrent application.
%% <p>This is the main entry point for the etorrent application.
%% It will be ensured that needed apps are correctly up and running,
%% and then the etorrent application will be started as a permanent app
%% in the VM.</p>
%% @end
start() ->
    %% Start dependent applications
    Fun = fun(Application) ->
            case application:start(Application) of
                ok -> ok;
                {error, {already_started, Application}} -> ok
            end
          end,
    [Fun(A) || A <- [crypto, inets, mnesia, sasl, gproc]],
    %% DB
    %% ok = mnesia:create_schema([node()]),
    etorrent_mnesia_init:init(),
    etorrent_mnesia_init:wait(),
    %% Etorrent
    application:start(etorrent, permanent).

%% @doc Application callback.
%% @end
start(_Type, _Args) ->
    PeerId = generate_peer_id(),
    etorrent_sup:start_link(PeerId).

%% @doc Application callback.
%% @end
stop() ->
    ok = application:stop(etorrent).

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
