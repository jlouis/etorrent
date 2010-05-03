%%%-------------------------------------------------------------------
%%% File    : dirwatcher_sup.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus.local.domain>
%%% License : See COPYING
%%% Description : Supervise the dirwatcher.
%%%
%%% Created : 11 Jul 2007 by Jesper Louis Andersen <jlouis@succubus.local.domain>
%%%-------------------------------------------------------------------
-module(etorrent_dirwatcher_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the supervisor
%%--------------------------------------------------------------------
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    DirWatcher = {etorrent_dirwatcher,
                  {etorrent_dirwatcher, start_link, []},
                  permanent, 2000, worker, [etorrent_dirwatcher]},
    {ok,{{one_for_one,1,60}, [DirWatcher]}}.

%%====================================================================
%% Internal functions
%%====================================================================
