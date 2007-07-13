%%%-------------------------------------------------------------------
%%% File    : torrent_pool_sup.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Supervisor for the pool of torrents
%%%
%%% Created : 13 Jul 2007 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(torrent_pool_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% TODO: Code for adding torrents here!

%%====================================================================
%% Supervisor callbacks
%%====================================================================
init([]) ->
    {ok,{{one_for_one,5, 60}, []}}.

%%====================================================================
%% Internal functions
%%====================================================================
