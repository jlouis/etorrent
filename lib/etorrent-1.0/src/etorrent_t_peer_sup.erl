%%%-------------------------------------------------------------------
%%% File    : etorrent_t_peer_sup.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Supervisor for a peer connection.
%%%
%%% Created : 10 Jul 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_t_peer_sup).

-behaviour(supervisor).

%% API
-export([start_link/6, add_sender/5]).

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
start_link(LocalPeerId, InfoHash, FilesystemPid, GroupPid, Id, {IP, Port}) ->
    supervisor:start_link(?MODULE, [LocalPeerId,
				    InfoHash,
				    FilesystemPid,
				    GroupPid,
				    Id,
				    {IP, Port}]).

add_sender(Pid, Socket, FileSystemPid, Id, RecvPid) ->
    Sender   = {sender, {etorrent_t_peer_send, start_link,
			 [Socket, FileSystemPid, Id, RecvPid]},
		permanent, 15000, worker, [etorrent_t_peer_send]},
    supervisor:start_child(Pid, Sender).

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
init([LocalPeerId, InfoHash, FilesystemPid, GroupPid, Id, {IP, Port}]) ->
    Reciever = {reciever, {etorrent_t_peer_recv, start_link,
			  [LocalPeerId, InfoHash, FilesystemPid, GroupPid, Id, self(),
			   {IP, Port}]},
		permanent, 15000, worker, [etorrent_t_peer_recv]},
    {ok, {{one_for_all, 0, 1}, [Reciever]}}.

%%====================================================================
%% Internal functions
%%====================================================================
