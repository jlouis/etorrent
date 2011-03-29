%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Supervise a torrent file.
%% <p>This supervisor controls a single torrent download. It sits at
%% the top of the supervisor tree for a torrent.</p>
%% @end
-module(etorrent_torrent_sup).
-behaviour(supervisor).

%% API
-export([start_link/3, start_child_tracker/5]).

%% Supervisor callbacks
-export([init/1]).
-ignore_xref([{'start_link', 3}]).

-type bcode() :: etorrent_types:bcode().
-type tier() :: etorrent_types:tier().


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
init([{Torrent, TorrentPath, TorrentIH}, PeerID, TorrentID]) ->
    Children = [
        scarcity_manager_spec(TorrentID, Torrent),
        torrent_control_spec(TorrentID, Torrent, TorrentPath, TorrentIH, PeerID),
        chunk_manager_spec(TorrentID, Torrent),
        io_sup_spec(TorrentID, Torrent),
        peer_pool_spec(TorrentID)],
    {ok, {{one_for_all, 1, 60}, Children}}.

scarcity_manager_spec(TorrentID, Torrent) ->
    Numpieces = length(etorrent_io:piece_sizes(Torrent)),
    {scarcity_mgr,
        {etorrent_scarcity, start_link, [TorrentID, Numpieces]},
        permanent, 5000, worker, [etorrent_scarcity]}.


chunk_manager_spec(TorrentID, Torrent) ->
    ValidPieces = [], % TODO - retrieve this from a persistent state-file/table.
    PieceSizes  = etorrent_io:piece_sizes(Torrent), 
    ChunkSize   = 16#4000, % TODO - get this value from a configuration file
    Args = [TorrentID, ChunkSize, ValidPieces, PieceSizes, lookup],
    {chunk_mgr,
        {etorrent_chunk_mgr, start_link, Args},
        permanent, 5000, worker, [etorrent_chunk_mgr]}.

torrent_control_spec(TorrentID, Torrent, TorrentFile, TorrentIH, PeerID) ->
    {control,
        {etorrent_torrent_ctl, start_link,
         [TorrentID, {Torrent, TorrentFile, TorrentIH}, PeerID]},
        permanent, 5000, worker, [etorrent_torrent_ctl]}.

io_sup_spec(TorrentID, Torrent) ->
    {fs_pool,
        {etorrent_io_sup, start_link, [TorrentID, Torrent]},
        transient, 5000, supervisor, [etorrent_io_sup]}.

peer_pool_spec(TorrentID) ->
    {peer_pool_sup,
        {etorrent_peer_pool, start_link, [TorrentID]},
        transient, 5000, supervisor, [etorrent_peer_pool]}.
