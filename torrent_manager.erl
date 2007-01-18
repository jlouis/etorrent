-module(torrent_manager).
-behaviour(gen_server).

-export([start_link/0]).
-export([handle_cast/2, handle_call/3, init/1, terminate/2]).
-export([handle_info/2, code_change/3]).
-export([start_torrent/2, stop_torrent/1]).

%% Callbacks
start_link() ->
    gen_server:start_link({local, torrent_manager}, torrent_manager, [], []).

init(_Args) ->
    io:format("Spawning torrent manager~n"),
    {ok, {ets:new(torrent_tracking_table, [named_table]), generate_peer_id()}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_info({'EXIT', Pid, Reason}, {TrackingMap, PeerId}) ->
    error_logger:error_report([{'Torrent EXIT', Reason}, {'State', {TrackingMap, PeerId}}]),
    [{File, Torrent}] = ets:match(TrackingMap, {Pid, '$1', '$2'}),
    ets:delete(TrackingMap, Pid),
    spawn_new_torrent(File, Torrent, PeerId, TrackingMap),
    {noreply, {TrackingMap, PeerId}};
handle_info(Info, State) ->
    error_logger:info_report([{'INFO', Info}, {'State', State}]),
    {noreply, State}.

spawn_new_torrent(F, Torrent, PeerId, TrackingMap) ->
    {ok, TorrentPid} = torrent:start_link(F, Torrent, PeerId),
    ets:insert(TrackingMap, {TorrentPid, F, Torrent}),
    torrent:start(TorrentPid).

terminate(shutdown, _State) ->
    ok.

handle_call(_A, _B, S) ->
    {noreply, S}.

handle_cast({start_torrent, F, Torrent}, {TrackingMap, PeerId}) ->
    spawn_new_torrent(F, Torrent, PeerId, TrackingMap),
    {noreply, {TrackingMap, PeerId}};
handle_cast({stop_torrent, F}, {TrackingMap, PeerId}) ->
    TorrentPid = ets:lookup(TrackingMap, F),
    torrent:stop(TorrentPid),
    ets:delete(TrackingMap, F),
    {noreply, {TrackingMap, PeerId}}.

%% Operations
start_torrent(File, Torrent) ->
    gen_server:cast(torrent_manager, {start_torrent, File, Torrent}).

stop_torrent(File) ->
    gen_server:cast(torrent_manager, {stop_torrent, File}).

%% Utility
generate_peer_id() ->
    "Setme".

