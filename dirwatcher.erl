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
	    process_added_files(Dir, sets:to_list(Added)),
	    io:format("Removed: ~s~n", [sets:to_list(Removed)]),
	    process_removed_files(sets:to_list(Removed)),
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

process_added_files(Dir, Added) ->
    %% for each file, try to parse it as a torrent file
    lists:foreach(fun(F) ->
			  case torrent:parse(F) of
			      {ok, Torrent} ->
				  torrent_manager ! {start_torrent, Dir, F, Torrent};
			      {not_a_torrent, Reason} ->
				  io:format("~s is not a Torrent: ~s~n", [F, Reason]);
			      {could_not_read_file, Reason} ->
				  io:format("~s could not be read: ~s~n", [F, Reason])
			  end
	      end,
	      Added).

process_removed_files(Removed) ->
    lists:foreach(fun(F) ->
			  torrent_manager ! {stop_torrent, F} end,
		  Removed).


