%%%-------------------------------------------------------------------
%%% File    : torrent_sup.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus.local.domain>
%%% Description : Supervision of torrent modules.
%%%
%%% Created : 13 Jul 2007 by Jesper Louis Andersen <jlouis@succubus.local.domain>
%%%-------------------------------------------------------------------
-module(torrent_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%%====================================================================
%% API functions
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the supervisor
%%--------------------------------------------------------------------
start_link() ->
    supervisor:start_link(?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================
%%--------------------------------------------------------------------
%% Func: init(Args) -> {ok,  {SupFlags,  [ChildSpec]}} |
%%                     ignore                          |
%%                     {error, Reason}
%% Description: Whenever a supervisor is started using
%% supervisor:start_link/[2,3], this function is called by the new process
%% to find out about restart strategy, maximum restart frequency and child
%% specifications.
%%--------------------------------------------------------------------
init([]) ->
    {ok, {{one_for_all, 1, 600}, []}}.

%%====================================================================
%% Internal functions
%%====================================================================
