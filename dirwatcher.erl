-module(dirwatcher).
-behaviour(gen_server).

-export([handle_cast/2, handle_call/3, init/1, terminate/2]).
-export([handle_info/2, code_change/3]).

-compile(export_all).

start_link(Dir) ->
    gen_server:start_link({local, dirwatcher}, dirwatcher, Dir, []).

init(Dir) ->
    io:format("Spawning Dirwatcher~n"),
    timer:send_interval(1000, self(), watch_directories),
    {ok, {Dir, empty_state()}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_info(_Foo, State) ->
    {noreply, State}.

terminate(shutdown, _State) ->
    ok.

handle_call(_A, _B, S) ->
    {noreply, S}.

handle_cast({report_on_files, Who}, {Dir, State}) ->
    Who ! sets:to_list(State),
    {noreply, {Dir, State}};
handle_cast(watch_directories, {Dir, State}) ->
    {Added, Removed, NewState} = scan_files_in_dir(Dir, State),
    AddedPred = sets:size(Added) > 0,
    RemovedPred = sets:size(Removed) >0,
    if
	AddedPred == true ->
	    io:format("Added: ~s~n", [sets:to_list(Added)]),
	    process_added_files(Dir, sets:to_list(Added));
	true ->
	    false
    end,

    if
	RemovedPred == true ->
	    io:format("Removed: ~s~n", [sets:to_list(Removed)]),
	    process_removed_files(sets:to_list(Removed));
	true ->
	    false
    end,
    {noreply, {Dir, NewState}}.

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


