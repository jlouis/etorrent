-module(torrent_manager).
-behaviour(gen_server).

-export([start_link/0]).
-export([handle_cast/2, handle_call/3, init/1, terminate/2]).
-export([handle_info/2, code_change/3]).

start_link() ->
    gen_server:start_link({local, torrent_manager}, torrent_manager, [], []).

init(_Args) ->
    io:format("Spawning torrent manager~n"),
    {ok, {empty_tracking_map(), generate_peer_id()}}.

empty_tracking_map() ->
    dict:new().

%% Todo: Device and create the peerid
generate_peer_id() ->
    "Setme".

handle_cast({start_torrent, Dir, F, Torrent}, {TrackingMap, PeerId}) ->
    TorrentPid = torrent:start(Dir, F, Torrent, PeerId),
    NewMap = dict:store(F, TorrentPid, TrackingMap),
    TorrentPid ! start,
    {noreply, {NewMap, PeerId}};
handle_cast({stop_torrent, F}, {TrackingMap, PeerId}) ->
    TorrentPid = dict:fetch(F, TrackingMap),
    TorrentPid ! stop,
    NewMap = dict:erase(F, TrackingMap),
    {noreply, {NewMap, PeerId}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_info(_Foo, State) ->
    {noreply, State}.

terminate(shutdown, _State) ->
    ok.

handle_call(_A, _B, S) ->
    {noreply, S}.
