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
-export([start_link/0, add_torrent/3, stop_torrent/1]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

add_torrent(File, Local_PeerId, Id) ->
    Torrent = {File,
	       {etorrent_t_sup, start_link, [File, Local_PeerId, Id]},
	       transient, infinity, supervisor, [etorrent_t_sup]},
    supervisor:start_child(?SERVER, Torrent).

stop_torrent(File) ->
    supervisor:terminate_child(?SERVER, File),
    supervisor:delete_child(?SERVER, File).

%%====================================================================
%% Supervisor callbacks
%%====================================================================
init([]) ->
    {ok,{{one_for_one, 1, 60}, []}}.

%%====================================================================
%% Internal functions
%%====================================================================
