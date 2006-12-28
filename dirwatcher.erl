-module(dirwatcher).

-compile(export_all).

start(Dir) ->
    spawn(dirwatcher, init, [Dir]).

init(Dir) ->
    io:format("Spawn~n"),
    timer:send_interval(10 * 1000, self(), watch_directories),
    register(dirwatcher, self()),
    dirwatcher_kernel(Dir, empty_state()).

dirwatcher_kernel(Dir, State) ->
    receive
	watch_directories ->
	    io:format("Timer ticking~n", []),
	    {Added, Removed, NewState} = scan_files_in_dir(Dir, State),
	    io:format("Added: ~s~n", [sets:to_list(Added)]),
	    io:format("Removed: ~s~n", [sets:to_list(Removed)]),
	    io:format("State: ~s~n", [sets:to_list(NewState)]),
	    dirwatcher:dirwatcher_kernel(Dir, NewState);
	{report_on_files, Who} ->
	    Who ! sets:to_list(State),
	    dirwatcher:dirwatcher_kernel(Dir, State)
    end.

empty_state() -> sets:new().

scan_files_in_dir(Dir, State) ->
    Files = filelib:fold_files(Dir, ".*\.torrent", false, fun(F, Accum) ->
								  [F | Accum] end, []),
    FilesSet = sets:from_list(Files),
    Added = sets:subtract(FilesSet, State),
    Removed = sets:subtract(State, FilesSet),
    NewState = FilesSet,
    {Added, Removed, NewState}.

report_files(Message, Files) ->
    io:format("~s~n", [Message]),
    lists:foreach(fun(F) ->
			   io:format("~s~n", F) end, sets:to_list(Files)).

