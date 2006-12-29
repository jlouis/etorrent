-module(torrent).
-compile(export_all).
-author("jesper.louis.andersen@gmail.com").


start(Dir, F, Torrent, PeerId) ->
    spawn(torrent, init, [Dir, F, Torrent, PeerId]).

init(_, F, Torrent, PeerId) ->
    StatePid = spawn(torrent_state, start, []),
    TrackerDelegatePid = spawn(tracker_delegate, start,
			       [self(), StatePid,
				get_url(Torrent),
				get_infohash(Torrent),
				PeerId]),
    torrent_loop(F, Torrent, StatePid, TrackerDelegatePid).

get_url(Torrent) ->
    case bcoding:search_dict("announce", Torrent) of
	{string, Url} ->
	    Url
    end.

get_infohash(Torrent) ->
    InfoDict = bcoding:search_dict("info", Torrent),
    Digest = crypto:sha((bcoding:encode(InfoDict))),
    %% We almost positively need to change this thing.
    {define_me, Digest}.

torrent_loop(F, _, StatePid, TrackerDelegatePid) ->
    io:format("Process for torrent ~s started", [F]),
    receive
	start ->
	    io:format("Starting torrent download of ~s~n", [F]),
	    TrackerDelegatePid ! start;
	stop ->
	    io:format("Stopping torrent ~s~n", [F]),
	    StatePid ! stop,
	    TrackerDelegatePid ! stop,
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

