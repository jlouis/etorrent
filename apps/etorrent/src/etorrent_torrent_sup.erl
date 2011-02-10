%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Supervise a torrent file.
%% <p>This supervisor controls a single torrent download. It sits at
%% the top of the supervisor tree for a torrent.</p>
%% @end
-module(etorrent_torrent_sup).

-behaviour(supervisor).

-include("types.hrl").

%% API
-export([start_link/3, start_child_tracker/5]).

%% Supervisor callbacks
-export([init/1]).
-ignore_xref([{'start_link', 3}]).
%% =======================================================================

%% @doc Start up the supervisor
%% @end
-spec start_link({bcode(), string(), binary()}, binary(), integer()) ->
                {ok, pid()} | ignore | {error, term()}.
start_link({Torrent, TorrentFile, TorrentIH}, Local_PeerId, Id) ->
    supervisor:start_link(?MODULE, [{Torrent, TorrentFile, TorrentIH}, Local_PeerId, Id]).

%% @doc start a child process of a tracker type.
%% <p>We do this after-the-fact as we like to make sure how complete the torrent
%% is before telling the tracker we are serving it. In fact, we can't accurately
%% report the "left" part to the tracker if it is not the case.</p>
%% @end
-spec start_child_tracker(pid(), [tier()], binary(), binary(), integer()) ->
                {ok, pid()} | {ok, pid(), term()} | {error, term()}.
start_child_tracker(Pid, UrlTiers, InfoHash, Local_Peer_Id, TorrentId) ->
    %% BEP 27 Private Torrent spec does not say this explicitly, but
    %% Azureus wiki does mention a bittorrent client that conforms to
    %% BEP 27 should behave like a classic one, i.e. no PEX or DHT.
    %% So only enable DHT support for non-private torrent here.
    case etorrent_torrent:is_private(TorrentId) of
        false -> _ = etorrent_dht:add_torrent(InfoHash, TorrentId);
        true -> ok
    end,
    Tracker = {tracker_communication,
               {etorrent_tracker_communication, start_link,
                [self(), UrlTiers, InfoHash, Local_Peer_Id, TorrentId]},
               permanent, 15000, worker, [etorrent_tracker_communication]},
    supervisor:start_child(Pid, Tracker).

%% ====================================================================

%% @private
init([{Torrent, TorrentFile, TorrentIH}, PeerId, Id]) ->
    FSPool = {fs_pool,
              {etorrent_io_sup, start_link, [Id, Torrent]},
              transient, infinity, supervisor, [etorrent_io_sup]},
    %FS = {fs,
    %      {etorrent_fs, start_link, [Id]},
    %      permanent, 2000, worker, [etorrent_fs]},
    Control = {control,
               {etorrent_torrent_ctl, start_link,
               [Id, {Torrent, TorrentFile, TorrentIH}, PeerId]},
               permanent, 20000, worker, [etorrent_torrent_ctl]},
    PeerPool = {peer_pool_sup,
                {etorrent_peer_pool, start_link, [Id]},
                transient, infinity, supervisor, [etorrent_peer_pool]},
    %{ok, {{one_for_all, 1, 60}, [FSPool, FS, Control, PeerPool]}}.
    {ok, {{one_for_all, 1, 60}, [Control, FSPool, PeerPool]}}.
