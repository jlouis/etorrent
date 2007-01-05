-module(torrent).
-compile(export_all).
-author("jesper.louis.andersen@gmail.com").


start(Dir, F, Torrent, PeerId) ->
    spawn(torrent, init, [Dir, F, Torrent, PeerId]).

init(_, F, Torrent, PeerId) ->
    StatePid = torrent_state:start(),
    TrackerDelegatePid = tracker_delegate:start(self(), StatePid,
						get_url(Torrent),
						get_infohash(Torrent),
						PeerId),
    io:format("Process for torrent ~s started~n", [F]),
    torrent_loop(F, Torrent, StatePid, TrackerDelegatePid).

torrent_loop(F, Torrent, StatePid, TrackerDelegatePid) ->
    io:format("Torrent looping...~n"),
    receive
	start ->
	    io:format("Starting torrent download of ~s~n", [F]),
	    io:format("TrackerDelegatePid ~w~n", [TrackerDelegatePid]),
	    TrackerDelegatePid ! start,
	    io:format("Message sent~n");
	stop ->
	    io:format("Stopping torrent ~s~n", [F]),
	    StatePid ! stop,
	    TrackerDelegatePid ! stop,
	    exit(normal);
	{tracker_request_failed, Err} ->
	    io:format("Tracker request failed: ~s~n", [Err])
    end,
    torrent:torrent_loop(F, Torrent, StatePid, TrackerDelegatePid).

%%%%% Subroutines

parse(File) ->
    case file:open(File, [read]) of
	{ok, IODev} ->
	    Data = read_data(IODev),
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

%% TODO: Implement the protocol for alternative URLs at some point.

get_url(Torrent) ->
    case bcoding:search_dict({string, "announce"}, Torrent) of
	{ok, {string, Url}} ->
	    Url
    end.

get_infohash(Torrent) ->
    {ok, InfoDict} = bcoding:search_dict({string, "info"}, Torrent),
    {ok, InfoString}  = bcoding:encode(InfoDict),
    Digest = crypto:sha(list_to_binary(InfoString)),
    %% We almost positively need to change this thing.
    hexify(Digest).

hexify(Digest) ->
    Characters = lists:map(fun(Item) ->
				   lists:concat(io_lib:format("~.16B",
							      [Item])) end,
			   binary_to_list(Digest)),
    lists:concat(Characters).



