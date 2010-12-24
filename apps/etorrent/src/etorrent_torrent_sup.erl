%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Supervise a torrent file.
%% <p>This supervisor controls a single torrent download. It sits at
%% the top of the supervisor tree for a torrent.</p>
%% @end
-module(etorrent_torrent_sup).

-behaviour(supervisor).

-include("types.hrl").

%% API
-export([start_link/3, add_tracker/5, add_peer/6]).

%% Supervisor callbacks
-export([init/1]).
-ignore_xref([{'start_link', 3}]).
%% =======================================================================

%% @doc Start up the supervisor
%% @end
-spec start_link(string(), binary(), integer()) -> {ok, pid()} | ignore | {error, term()}.
start_link(File, Local_PeerId, Id) ->
    supervisor:start_link(?MODULE, [File, Local_PeerId, Id]).

%% @doc Add the tracker process to the supervisor
%% <p>We do this after-the-fact as we like to make sure how complete the torrent
%% is before telling the tracker we are serving it. In fact, we can't accurately
%% report the "left" part to the tracker if it is not the case.</p>
%% @end
-spec add_tracker(pid(), [tier()], binary(), binary(), integer()) -> {ok, pid()} | {ok, pid(), term()} | {error, term()}.
add_tracker(Pid, UrlTiers, InfoHash, Local_Peer_Id, TorrentId) ->
    _ = etorrent_dht:add_torrent(InfoHash, TorrentId),
    Tracker = {tracker_communication,
               {etorrent_tracker_communication, start_link,
                [self(), UrlTiers, InfoHash, Local_Peer_Id, TorrentId]},
               permanent, 15000, worker, [etorrent_tracker_communication]},
    supervisor:start_child(Pid, Tracker).

%% @doc Add a peer to the torrent peer pool.
%% <p>In general, this is a simple call-through function, which hinges on the
%% peer_pools add_peer/7 function. It is just cleaner to call through this
%% supervisor, as it has the knowledge about the peer pool pid.</p>
%% @end
-spec add_peer(binary(), binary(), integer(), {ip(), integer()}, [capabilities()],
	       port()) ->
        {ok, pid(), pid()} | {error, term()}.
add_peer(PeerId, InfoHash, TorrentId, {IP, Port}, Capabilities, Socket) ->
    GroupPid = gproc:lookup_local_name({torrent, TorrentId, peer_pool_sup}),
    etorrent_peer_pool:add_peer(
      GroupPid,
      PeerId,
      InfoHash,
      TorrentId,
      {IP, Port},
      Capabilities,
      Socket).

%% ====================================================================

%% @private
init([Path, PeerId, Id]) ->
    FSPool = {fs_pool,
              {etorrent_io_sup, start_link, [Id, Path]},
              transient, infinity, supervisor, [etorrent_io_sup]},
    %FS = {fs,
    %      {etorrent_fs, start_link, [Id]},
    %      permanent, 2000, worker, [etorrent_fs]},
    Control = {control,
               {etorrent_t_control, start_link, [Id, Path, PeerId]},
               permanent, 20000, worker, [etorrent_t_control]},
    PeerPool = {peer_pool_sup,
                {etorrent_peer_pool, start_link, [Id]},
                transient, infinity, supervisor, [etorrent_peer_pool]},
    %{ok, {{one_for_all, 1, 60}, [FSPool, FS, Control, PeerPool]}}.
    {ok, {{one_for_all, 1, 60}, [Control, FSPool, PeerPool]}}.
