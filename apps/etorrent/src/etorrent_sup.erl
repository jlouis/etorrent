%%%-------------------------------------------------------------------
%%% File    : etorrent.erl
%%% Author  : User Jlouis <jesper.louis.andersen@gmail.com>
%%% License : See COPYING
%%% Description : Start up etorrent and supervise it.
%%%
%%% Created : 30 Jan 2007 by User Jlouis <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_sup).

-behaviour(supervisor).

-include("supervisor.hrl").
-include("log.hrl").

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%% ====================================================================
-spec start_link([binary()]) -> {ok, pid()} | ignore | {error, term()}.
start_link(PeerId) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [PeerId]).


%% ====================================================================
init([PeerId]) ->
    ?INFO([etorrent_supervisor_starting, PeerId]),
    Torrent      = ?CHILD(etorrent_torrent),
    FSJanitor    = ?CHILD(etorrent_fs_janitor),
    TrackingMap  = ?CHILD(etorrent_tracking_map),
    Peer         = ?CHILD(etorrent_peer),
    Counters     = ?CHILD(etorrent_counters),
    EventManager = ?CHILD(etorrent_event_mgr),
    PeerMgr      = ?CHILDP(etorrent_peer_mgr, [PeerId]),
    FastResume   = ?CHILD(etorrent_fast_resume),
    RateManager  = ?CHILD(etorrent_rate_mgr),
    PieceManager = ?CHILD(etorrent_piece_mgr),
    ChunkManager = ?CHILD(etorrent_chunk_mgr),
    Choker       = ?CHILDP(etorrent_choker, [PeerId]),
    Listener     = ?CHILD(etorrent_listener),
    AcceptorSup = {acceptor_sup,
                   {etorrent_acceptor_sup, start_link, [PeerId]},
                   permanent, infinity, supervisor, [etorrent_acceptor_sup]},
    TorrentMgr   = ?CHILDP(etorrent_mgr, [PeerId]),
    DirWatcherSup = {dirwatcher_sup,
                  {etorrent_dirwatcher_sup, start_link, []},
                  transient, infinity, supervisor, [etorrent_dirwatcher_sup]},
    TorrentPool = {torrent_pool_sup,
                   {etorrent_t_pool_sup, start_link, []},
                   transient, infinity, supervisor, [etorrent_t_pool_sup]},

    {ok, {{one_for_all, 3, 60},
          [Torrent, FSJanitor, TrackingMap, Peer,
           Counters, EventManager, PeerMgr, 
           FastResume, RateManager, PieceManager,
           ChunkManager, Choker, Listener, AcceptorSup,
           TorrentMgr, DirWatcherSup, TorrentPool]}}.
