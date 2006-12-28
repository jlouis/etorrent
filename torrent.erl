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
	    io:format("Stopping torrent ~s~n", [F]),
	    exit(normal)
    end.

parse(File) ->
    case file:open(File, [read]) of
	{ok, IODev} ->
	    Data = read_data(IODev),
	    io:format("~B~n", [length(Data)]),
	    case bcoding:decode(Data) of
		{ok, Torrent} ->
		    {ok, Torrent};
		{error, Reason} ->
		    {not_a_torrent, Reason}
	    end;
	{error, Reason} ->
	    {could_not_read_file, Reason}
    end.

read_data(IODev) ->
    eat_lines(IODev, []).

eat_lines(IODev, Accum) ->
    case io:get_chars(IODev, ">", 8192) of
	eof ->
	    lists:concat(lists:reverse(Accum));
	String ->
	    eat_lines(IODev, [String | Accum])
    end.

