%%%-------------------------------------------------------------------
%%% File    : etorrent_t_sup.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus.local.domain>
%%% License : See COPYING
%%% Description : Supervision of torrent modules.
%%%
%%% Created : 13 Jul 2007 by
%%%     Jesper Louis Andersen <jlouis@succubus.local.domain>
%%%-------------------------------------------------------------------
-module(etorrent_t_sup).

-behaviour(supervisor).

-include("types.hrl").

%% API
-export([start_link/3, add_tracker/5, get_pid/2,
         add_peer/6]).

%% Supervisor callbacks
-export([init/1]).

%% =======================================================================
% @doc Start up the supervisor
% @end
-spec start_link(string(), binary(), integer()) -> {ok, pid()} | ignore | {error, term()}.
start_link(File, Local_PeerId, Id) ->
    supervisor:start_link(?MODULE, [File, Local_PeerId, Id]).

% @doc Return the Child pid of a given supervisor, identified by Name.
% <p><emph>Assumption:</emph> The Name exists, or this function crashes</p>
% @end
-spec get_pid(pid(), atom()) -> pid().
get_pid(Pid, Name) ->
    {value, {_, Child, _, _}} =
        lists:keysearch(Name, 1, supervisor:which_children(Pid)),
    Child.

% @doc Add the tracker process to the supervisor
% <p>We do this after-the-fact as we like to make sure how complete the torrent
% is before telling the tracker we are serving it. In fact, we can't accurately
% report the "left" part to the tracker if it is not the case.</p>
% @end
-spec add_tracker(pid(), string(), binary(), binary(), integer()) -> {ok, pid()} | {ok, pid(), term()} | {error, term()}.
add_tracker(Pid, URL, InfoHash, Local_Peer_Id, TorrentId) ->
    Tracker = {tracker_communication,
               {etorrent_tracker_communication, start_link,
                [self(), URL, InfoHash, Local_Peer_Id, TorrentId]},
               permanent, 15000, worker, [etorrent_tracker_communication]},
    supervisor:start_child(Pid, Tracker).

% @doc Add a peer to the torrent peer pool.
% <p>In general, this is a simple call-through function, which hinges on the
% peer_pools add_peer/7 function. It is just cleaner to call through this
% supervisor, as it has the knowledge about the peer pool pid.</p>
% @end
-spec add_peer(pid(), binary(), binary(), integer(), {ip(), integer()}, port()) ->
        {ok, pid(), pid()} | {error, term()}.
add_peer(Pid, PeerId, InfoHash, TorrentId, {IP, Port}, Socket) ->
    FSPid = get_pid(Pid, fs),
    GroupPid = get_pid(Pid, peer_pool_sup),
    etorrent_peer_pool_sup:add_peer(
                                GroupPid,
                                PeerId,
                                InfoHash,
                                FSPid,
                                TorrentId,
                                {IP, Port},
                                Socket).

%% ====================================================================
init([Path, PeerId, Id]) ->
    FSPool = {fs_pool,
              {etorrent_fs_pool_sup, start_link, []},
              transient, infinity, supervisor, [etorrent_fs_pool_sup]},
    FS = {fs,
          {etorrent_fs, start_link, [Id, self()]},
          permanent, 2000, worker, [etorrent_fs]},
    Control = {control,
               {etorrent_t_control, start_link, [Id, Path, PeerId]},
               permanent, 20000, worker, [etorrent_t_control]},
    PeerPool = {peer_pool_sup,
                {etorrent_peer_pool_sup, start_link, []},
                transient, infinity, supervisor, [etorrent_peer_pool_sup]},
    {ok, {{one_for_all, 1, 60}, [FSPool, FS, Control, PeerPool]}}.
