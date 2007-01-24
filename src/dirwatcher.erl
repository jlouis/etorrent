-module(dirwatcher).
-behaviour(gen_server).

-export([handle_cast/2, handle_call/3, init/1, terminate/2]).
-export([handle_info/2, code_change/3, start_link/1, watch_dirs/0]).

start_link(Dir) ->
    gen_server:start_link({local, dirwatcher}, dirwatcher, Dir, []).

init(Dir) ->
    io:format("Spawning Dirwatcher~n"),
    timer:apply_interval(1000, dirwatcher, watch_dirs, []),
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
    lists:foreach(fun(F) -> handle_new_torrent(F) end, sets:to_list(Added)),
    lists:foreach(fun(F) -> torrent_manager:stop_torrent(F) end, sets:to_list(Removed)),
    {noreply, {Dir, NewState}}.


%% Operations
watch_dirs() ->
    gen_server:cast(dirwatcher, watch_directories).

empty_state() -> sets:new().

scan_files_in_dir(Dir, State) ->
    Files = filelib:fold_files(Dir, ".*\.torrent", false, fun(F, Accum) ->
								  [F | Accum] end, []),
    FilesSet = sets:from_list(Files),
    Added = sets:subtract(FilesSet, State),
    Removed = sets:subtract(State, FilesSet),
    NewState = FilesSet,
    {Added, Removed, NewState}.

handle_new_torrent(F) ->
    case metainfo:parse(F) of
	{ok, Torrent} ->
	    torrent_manager:start_torrent(F, Torrent);
	{not_a_torrent, Reason} ->
	    error_logger:warning_msg("~s is not a torrent: ~s~n", [F, Reason]);
	{could_not_read_file, Reason} ->
	    error_logger:warning_msg("~s could not be read: ~s~n", [F, Reason])
    end.


