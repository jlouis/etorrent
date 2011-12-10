%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Supervise a pool of peers.
%% <p>This module is a simple supervisor of Peers</p>
%% @end
-module(etorrent_peer_pool).
-behaviour(supervisor).

%% API
-export([start_link/1, start_child/6, start_child/7]).

%% Supervisor callbacks
-export([init/1]).
-define(SERVER, ?MODULE).

-type ipaddr() :: etorrent_types:ipaddr().
-type portnum() :: etorrent_types:portnum().
-type capabilities() :: etorrent_types:capabilities().


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
    start_child("no_tracker_url", PeerId, InfoHash, Id,
                {IP, Port}, Capabilities, Socket).
-spec start_child(string(), binary(), binary(), integer(),
                  {ipaddr(), portnum()},
                  [capabilities()],
                  port()) ->
                         {ok, pid(), pid()} | {error, term()}.
start_child(TrackerUrl, PeerId, InfoHash, Id,
            {IP, Port}, Capabilities, Socket) ->
    GroupPid = gproc:lookup_local_name({torrent, Id, peer_pool_sup}),
    case supervisor:start_child(GroupPid,
                                [TrackerUrl,
                                 PeerId, InfoHash,
                                 Id,
                                 {IP, Port},
                                 Capabilities,
                                 Socket]) of
        {ok, _Pid} ->
            RecvPid = etorrent_peer_recv:await_server(Socket),
            ControlPid = etorrent_peer_control:await_server(Socket),
            {ok, RecvPid, ControlPid};
        {error, Reason} ->
            lager:warning("Error starting child: ~p", [Reason]),
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
