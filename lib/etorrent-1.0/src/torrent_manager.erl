-module(torrent_manager).
-behaviour(gen_server).

-include("version.hrl").

-export([start_link/0, start_torrent/1, stop_torrent/1]).
-export([handle_cast/2, handle_call/3, init/1, terminate/2]).
-export([handle_info/2, code_change/3]).

-define(SERVER, ?MODULE).

%% API
start_link() ->
    gen_server:start_link({local, torrent_manager}, torrent_manager, [], []).

start_torrent(File) ->
    gen_server:cast(torrent_manager, {start_torrent, File}).

stop_torrent(File) ->
    gen_server:cast(torrent_manager, {stop_torrent, File}).

%% Callbacks
init(_Args) ->
    {ok, {ets:new(torrent_tracking_table, [named_table]), generate_peer_id()}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_info({'EXIT', Pid, Reason}, {TrackingMap, PeerId}) ->
    error_logger:error_report([{'Torrent EXIT', Reason},
			       {'State', {TrackingMap, PeerId}}]),
    [{File}] = ets:match(TrackingMap, {Pid, '$1', '$2'}),
    ets:delete(TrackingMap, Pid),
    spawn_new_torrent(File, PeerId, TrackingMap),
    {noreply, {TrackingMap, PeerId}};
handle_info(Info, State) ->
    error_logger:info_report([{'INFO', Info}, {'State', State}]),
    {noreply, State}.

terminate(shutdown, _State) ->
    ok.

handle_call(_A, _B, S) ->
    {noreply, S}.

handle_cast({start_torrent, F}, {TrackingMap, PeerId}) ->
    spawn_new_torrent(F, PeerId, TrackingMap),
    {noreply, {TrackingMap, PeerId}};

handle_cast({stop_torrent, F}, {TrackingMap, PeerId}) ->
    TorrentPid = ets:lookup(TrackingMap, F),
    torrent_control:stop(TorrentPid),
    ets:delete(TrackingMap, F),
    {noreply, {TrackingMap, PeerId}}.

%% Internal functions
spawn_new_torrent(F, PeerId, TrackingMap) ->
    {ok, TorrentSupervisor} = torrent_pool_sup:spawn_new_torrent(),
    sys:trace(TorrentSupervisor, true),
    {ok, TorrentControl} = torrent_sup:add_control(TorrentSupervisor),
    sys:trace(TorrentControl, true),
    ok = torrent_control:load_new_torrent(TorrentControl, F, PeerId),
    ets:insert(TrackingMap, {TorrentSupervisor, TorrentControl, F}).

%% Utility
generate_peer_id() ->
    Rand = io_lib:fwrite("~B----------", [random_source:random_peer_id()]),
    io_lib:format("-ET~s-~12s", [?VERSION, Rand]).


