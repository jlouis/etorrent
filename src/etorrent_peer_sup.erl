-module(etorrent_peer_sup).

-behaviour(supervisor).

-include("types.hrl").

%% API
-export([start_link/7, get_pid/2]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%% ====================================================================
-spec start_link(binary(), binary(), pid(), integer(), {ip(), integer()},
		 [capabilities()], port()) ->
            {ok, pid()} | ignore | {error, term()}.
start_link(LocalPeerId, InfoHash, FilesystemPid, Id, {IP, Port}, Capabilities, Socket) ->
    supervisor:start_link(?MODULE, [LocalPeerId,
                                    InfoHash,
                                    FilesystemPid,
                                    Id,
                                    {IP, Port},
				    Capabilities,
				    Socket]).

%% @todo Move this function to a more global spot. It is duplicated
% @doc return the pid() of a given child.
% @end
-spec get_pid(pid(), atom()) -> {ok, pid()}.
get_pid(Pid, Name) ->
    {value, {_, Child, _, _}} =
        lists:keysearch(Name, 1, supervisor:which_children(Pid)),
    {ok, Child}.

%% ====================================================================
init([LocalPeerId, InfoHash, FilesystemPid, Id, {IP, Port}, Caps, Socket]) ->
    Control = {control, {etorrent_peer_control, start_link,
                          [LocalPeerId, InfoHash, FilesystemPid, Id, self(),
                           {IP, Port}, Caps, Socket]},
                permanent, 15000, worker, [etorrent_peer_control]},
    Receiver = {receiver, {etorrent_peer_recv, start_link,
                          [Id, Socket, self()]},
                      permanent, 15000, worker, [etorrent_peer_recv]},
    Sender   = {sender,   {etorrent_peer_send, start_link,
                          [Socket, FilesystemPid, Id, false,
                           self()]},
                permanent, 15000, worker, [etorrent_peer_send]},
    {ok, {{one_for_all, 0, 1}, [Control, Sender, Receiver]}}.
