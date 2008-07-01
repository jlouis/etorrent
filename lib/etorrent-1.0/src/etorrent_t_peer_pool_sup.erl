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
-export([start_link/0, add_peer/6]).

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

add_peer(GroupPid, LocalPeerId, InfoHash, FilesystemPid, Parent, Id) ->
    supervisor:start_child(GroupPid, [LocalPeerId, InfoHash,
				     FilesystemPid, Parent, Id]).

%%====================================================================
%% Supervisor callbacks
%%====================================================================
init([]) ->
    PeerRecvs = {peer_recv,
		 {etorrent_t_peer_recv, start_link, []},
		 transient, 10000, supervisor, [etorrent_t_peer_recv]},
    {ok, {{simple_one_for_one, 5, 60}, [PeerRecvs]}}.

%%====================================================================
%% Internal functions
%%====================================================================
