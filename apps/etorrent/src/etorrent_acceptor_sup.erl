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
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

-define(DEFAULT_AMOUNT_OF_ACCEPTORS, 5).
-define(SERVER, ?MODULE).

%%====================================================================
%% @doc Starts the supervisor
%% @end
-spec start_link(string()) -> {ok, pid()} | ignore | {error, term()}.
start_link(PeerId) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, [PeerId]).

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
init([PeerId]) ->
    Children = build_children(PeerId, ?DEFAULT_AMOUNT_OF_ACCEPTORS),
    {ok, {{one_for_one, 1, 60}, Children}}.

%%====================================================================
%% Internal functions
%%====================================================================

build_children(_PeerId, 0) -> [];
build_children(PeerId, N) ->
    Id = {acceptor, N},
    ChildSpec = {Id,
                 {etorrent_acceptor, start_link, [PeerId]},
                 permanent, 2000, worker, [etorrent_acceptor]},
    [ChildSpec | build_children(PeerId, N-1)].
