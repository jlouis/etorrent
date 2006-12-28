-module(torrent_manager).

-compile(export_all).


start() ->
    Pid = spawn(torrent_manager, init, []),
    register(torrent_manager, Pid).

init() ->
    manager_loop(empty_tracking_map()).

empty_tracking_map() ->
    dict:new().

manager_loop(TrackingMap) ->
    receive
	{start_torrent, Dir, F, Torrent} ->
	    TorrentPid = torrent:start(Dir, F, Torrent),
	    NewMap = dict:store(F, TorrentPid, TrackingMap),
	    torrent_manager:manager_loop(NewMap);
	{stop_torrent, F} ->
	    TorrentPid = dict:fetch(F, TrackingMap),
	    TorrentPid ! stop,
	    NewMap = dict:erase(F, TrackingMap),
	    torrent_manager:manager_loop(NewMap)
    end.
