%%%-------------------------------------------------------------------
%%% File    : etorrent_acceptor_sup.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Supervise a set of acceptor processes.
%%%
%%% Created : 25 Aug 2007 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_acceptor_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(DEFAULT_AMOUNT_OF_ACCEPTORS, 5).
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
    Children = build_children(?DEFAULT_AMOUNT_OF_ACCEPTORS),
    {ok, {{one_for_one, 1, 60}, Children}}.

%%====================================================================
%% Internal functions
%%====================================================================

build_children(N) ->
    build_children(N, []).

build_children(0, Acc) ->
    Acc;
build_children(N, Acc) ->
    ID = {acceptor, N},
    ChildSpec = {ID,
		 {etorrent_acceptor, start_link, []},
		 permanent, 2000, worker, [etorrent_acceptor]},
    build_children(N-1, [ChildSpec | Acc]).
