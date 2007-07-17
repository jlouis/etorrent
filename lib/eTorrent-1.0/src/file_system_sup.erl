%%%-------------------------------------------------------------------
%%% File    : file_system_sup.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Supervise a file system process.
%%%
%%% Created : 13 Jul 2007 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(file_system_sup).

-behaviour(supervisor).

%% API
-export([start_link/1]).

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
start_link(FileDict) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, [FileDict]).

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
init([FileDict]) ->
    FS = {file_system,
	  {file_system, start_link, [FileDict]},
	  permanent, 20000, worker, [file_system]},
    {ok,{{one_for_all,0,1}, [FS]}}.

%%====================================================================
%% Internal functions
%%====================================================================
