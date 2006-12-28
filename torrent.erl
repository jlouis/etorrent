-module(torrent).
-compile(export_all).
-author("jesper.louis.andersen@gmail.com").


start(Dir, F, Torrent) ->
    spawn(torrent, init, [Dir, F, Torrent]).

init(_, F, Torrent) ->
    torrent_loop(F, Torrent).

torrent_loop(F, _) ->
    io:format("Process for torrent ~s started", [F]),
    receive
	stop ->
	    exit(normal)
    end.


