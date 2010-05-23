-module(etorrent_peer_sup).

-behaviour(supervisor).

%% API
-export([start_link/6, get_pid/2]).

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
start_link(LocalPeerId, InfoHash, FilesystemPid, Id, {IP, Port}, Socket) ->
    supervisor:start_link(?MODULE, [LocalPeerId,
                                    InfoHash,
                                    FilesystemPid,
                                    Id,
                                    {IP, Port}, Socket]).

get_pid(Pid, Name) ->
    {value, {_, Child, _, _}} =
        lists:keysearch(Name, 1, supervisor:which_children(Pid)),
    {ok, Child}.

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
init([LocalPeerId, InfoHash, FilesystemPid, Id, {IP, Port}, Socket]) ->
    Control = {control, {etorrent_peer_control, start_link,
                          [LocalPeerId, InfoHash, FilesystemPid, Id, self(),
                           {IP, Port}, Socket]},
                permanent, 15000, worker, [etorrent_peer_control]},
    Receiver = {receiver, {etorrent_peer_recv, start_link,
                          [Id, Socket, self()]},
                      permanent, 15000, worker, [etorrent_peer_recv]},
    Sender   = {sender,   {etorrent_peer_send, start_link,
                          [Socket, FilesystemPid, Id, false,
                           self()]},
                permanent, 15000, worker, [etorrent_peer_send]},
    {ok, {{one_for_all, 0, 1}, [Control, Sender, Receiver]}}.

%%====================================================================
%% Internal functions
%%====================================================================
