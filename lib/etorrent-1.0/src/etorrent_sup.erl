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

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================
start_link(PeerId) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [PeerId]).

%%====================================================================
%% Supervisor callbacks
%%====================================================================
init([PeerId]) ->
    error_logger:info_report([etorrent_supervisor_starting, PeerId]),
    Torrent  = {torrent,
                {etorrent_torrent, start_link, []},
                permanent, 2000, worker, [etorrent_torrent]},
    TrackingMap = {tracking_map,
                   {etorrent_tracking_map, start_link, []},
                    permanent, 2000, worker, [etorrent_tracking_map]},
    Counters = {counters,
                {etorrent_counters, start_link, []},
                permanent, 2000, worker, [etorrent_counters]},
    EventManager = {event_manager,
                    {etorrent_event_mgr, start_link, []},
                    permanent, 2000, worker, [etorrent_event_mgr]},
    PeerMgr = {peer_mgr,
                  {etorrent_peer_mgr, start_link, [PeerId]},
                  permanent, 5000, worker, [etorrent_peer_mgr]},
    FastResume = {fast_resume,
                  {etorrent_fast_resume, start_link, []},
                  transient, 5000, worker, [etorrent_fast_resume]},
    RateManager = {rate_manager,
                   {etorrent_rate_mgr, start_link, []},
                   permanent, 5000, worker, [etorrent_rate_mgr]},
    PieceManager = {etorrent_piece_mgr,
                    {etorrent_piece_mgr, start_link, []},
                    permanent, 15000, worker, [etorrent_piece_mgr]},
    ChunkManager = {etorrent_chunk_mgr,
                    {etorrent_chunk_mgr, start_link, []},
                    permanent, 15000, worker, [etorrent_chunk_mgr]},
    Choker = {choker,
              {etorrent_choker, start_link, [PeerId]},
              permanent, 5000, worker, [etorrent_choker]},
    Listener = {listener,
                {etorrent_listener, start_link, []},
                permanent, 2000, worker, [etorrent_listener]},
    AcceptorSup = {acceptor_sup,
                   {etorrent_acceptor_sup, start_link, [PeerId]},
                   permanent, infinity, supervisor, [etorrent_acceptor_sup]},
    TorrentMgr = {manager,
                  {etorrent_mgr, start_link, [PeerId]},
                  permanent, 2000, worker, [etorrent_mgr]},
    DirWatcherSup = {dirwatcher_sup,
                  {etorrent_dirwatcher_sup, start_link, []},
                  transient, infinity, supervisor, [etorrent_dirwatcher_sup]},
    TorrentPool = {torrent_pool_sup,
                   {etorrent_t_pool_sup, start_link, []},
                   transient, infinity, supervisor, [etorrent_t_pool_sup]},

    {ok, {{one_for_all, 3, 60},
          [Torrent, TrackingMap,
           Counters, EventManager, PeerMgr, FastResume, RateManager, PieceManager,
           ChunkManager, Choker, Listener, AcceptorSup, TorrentMgr, DirWatcherSup,
           TorrentPool]}}.

%%====================================================================
%% Internal functions
%%====================================================================
