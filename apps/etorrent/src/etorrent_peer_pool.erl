%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Supervise a pool of peers.
%% <p>This module is a simple supervisor of Peers</p>
%% @end
-module(etorrent_peer_pool).

-behaviour(supervisor).

-include("types.hrl").
-include("log.hrl").

%% API
-export([start_link/1, start_child/6]).

%% Supervisor callbacks
-export([init/1]).
-ignore_xref([{'start_link', 1}]).
-define(SERVER, ?MODULE).

%% ====================================================================

%% @doc Start the pool supervisor
%% @end
-spec start_link(integer()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Id) -> supervisor:start_link(?MODULE, [Id]).

%% @doc Add a peer to the supervisor pool.
%% <p>Post-factum, when new peers arrives, or we deplete the number of connected
%% peer below a certain threshold, we add new peers. When this happens, we call
%% the add_peer/7 function given here. It sets up a peer and adds it to the
%% supervisor.</p>
%% @end
-spec start_child(binary(), binary(), integer(), {ipaddr(), portnum()},
	       [capabilities()],
	       port()) ->
        {ok, pid(), pid()} | {error, term()}.
start_child(PeerId, InfoHash, Id, {IP, Port}, Capabilities, Socket) ->
    GroupPid = gproc:lookup_local_name({torrent, Id, peer_pool_sup}),
    case supervisor:start_child(GroupPid,
				[PeerId, InfoHash,
				 Id,
				 {IP, Port},
				 Capabilities,
				 Socket]) of
        {ok, _Pid} ->
	    RecvPid = gproc:lookup_local_name({peer, Socket, receiver}),
	    ControlPid = gproc:lookup_local_name({peer, Socket, control}),
	    {ok, RecvPid, ControlPid};
        {error, Reason} ->
            ?ERR([{start_child_peer, Reason}]),
            {error, Reason}
    end.

%% ====================================================================

%% @private
init([Id]) ->
    gproc:add_local_name({torrent, Id, peer_pool_sup}),
    ChildSpec = {child,
                 {etorrent_peer_sup, start_link, []},
                 temporary, infinity, supervisor, [etorrent_peer_sup]},
    {ok, {{simple_one_for_one, 50, 3600}, [ChildSpec]}}.
