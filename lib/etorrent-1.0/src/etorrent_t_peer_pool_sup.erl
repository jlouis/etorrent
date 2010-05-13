%%%-------------------------------------------------------------------
%%% File    : etorrent_t_peer_pool_sup.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Supervise a group of peer processes.
%%%
%%% Created : 17 Aug 2007 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_t_peer_pool_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, add_peer/7]).

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
    supervisor:start_link(?MODULE, []).

%%--------------------------------------------------------------------
%% Function: add_peer/6
%% Description: Add a peer to the supervisor pool. Returns the
%% receiver process hooked on the supervisor.
%%--------------------------------------------------------------------
add_peer(GroupPid, LocalPeerId, InfoHash, FilesystemPid, Id,
         {IP, Port}, Socket) ->
    case supervisor:start_child(GroupPid, [LocalPeerId, InfoHash,
                                                  FilesystemPid, Id,
                                                  {IP, Port}, Socket]) of
        {ok, Pid} ->
                Children = supervisor:which_children(Pid),
                {value, {_, Child, _, _}} = lists:keysearch(receiver, 1, Children),
                {ok, Child};
        {error, Reason} ->
            error_logger:error_report({add_peer_error, Reason}),
            {error, Reason}
    end.


%%====================================================================
%% Supervisor callbacks
%%====================================================================
init([]) ->
    ChildSpec = {child,
                 {etorrent_t_peer_sup, start_link, []},
                 temporary, infinity, supervisor, [etorrent_t_peer_sup]},
    {ok, {{simple_one_for_one, 15, 60}, [ChildSpec]}}.
