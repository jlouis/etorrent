-module(etorrent_peer_sup).

-behaviour(supervisor).

-include("types.hrl").

%% API
-export([start_link/6]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).
-ignore_xref([{'start_link', 6}]).
%% ====================================================================
-spec start_link(binary(), binary(), integer(), {ip(), integer()},
		 [capabilities()], port()) ->
            {ok, pid()} | ignore | {error, term()}.
start_link(LocalPeerId, InfoHash, Id, {IP, Port}, Capabilities, Socket) ->
    supervisor:start_link(?MODULE, [LocalPeerId,
                                    InfoHash,
                                    Id,
                                    {IP, Port},
				    Capabilities,
				    Socket]).

%% ====================================================================
init([LocalPeerId, InfoHash, Id, {IP, Port}, Caps, Socket]) ->
    Control = {control, {etorrent_peer_control, start_link,
                          [LocalPeerId, InfoHash, Id, {IP, Port},
			   Caps, Socket]},
                permanent, 15000, worker, [etorrent_peer_control]},
    Receiver = {receiver, {etorrent_peer_recv, start_link,
                          [Id, Socket]},
                      permanent, 15000, worker, [etorrent_peer_recv]},
    Sender   = {sender,   {etorrent_peer_send, start_link,
                          [Socket, Id, false]},
                permanent, 15000, worker, [etorrent_peer_send]},
    {ok, {{one_for_all, 0, 1}, [Control, Sender, Receiver]}}.
