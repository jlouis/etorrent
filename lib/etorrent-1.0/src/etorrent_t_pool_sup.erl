%%%-------------------------------------------------------------------
%%% File    : etorrent_t_pool_sup.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% License : See COPYING
%%% Description : Supervisor for the pool of torrents
%%%
%%% Created : 13 Jul 2007 by
%%%     Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_t_pool_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, spawn_new_torrent/2]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

spawn_new_torrent(File, Local_PeerId) ->
    supervisor:start_child(?SERVER, [File, Local_PeerId]).

%%====================================================================
%% Supervisor callbacks
%%====================================================================
init([]) ->
    Ts = {etorrent_t_sup,
	  {etorrent_t_sup, start_link, []},
	  temporary, infinity, supervisor, [etorrent_t_sup]},
    {ok,{{simple_one_for_one, 1, 60}, [Ts]}}.

%%====================================================================
%% Internal functions
%%====================================================================
