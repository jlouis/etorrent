%%%-------------------------------------------------------------------
%%% File    : dirwatcher.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus>
%%% Description : Watch a directory for the presence of torrent files.
%%%               Send commands when files are added and removed.
%%%
%%% Created : 24 Jan 2007 by Jesper Louis Andersen <jlouis@succubus>
%%%-------------------------------------------------------------------
-module(dirwatcher).
-author("Jesper Louis Andersen <jesper.louis.andersen@gmail.com>").
-behaviour(gen_server).

-vsn("1").
%% API
-export([start_link/0, watch_dirs/0, dir_watched/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {dir = none,
	        fileset = none}).
-define(WATCH_WAIT_TIME, 1000).
-define(SERVER, ?MODULE).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

watch_dirs() ->
    gen_server:cast(dirwatcher, watch_directories).

dir_watched() ->
    gen_server:call(dirwatcher, dir_watched).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([]) ->
    timer:apply_interval(?WATCH_WAIT_TIME, ?MODULE, watch_dirs, []),
    {ok, Dir} = application:get_env(etorrent, dir),
    {ok, #state{dir = Dir, fileset = empty_state()}}.

handle_call(report_on_files, _Who, S) ->
    {reply, sets:to_list(S#state.fileset), S};
handle_call(dir_watched, _Who, S) ->
    {reply, S#state.dir, S};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(watch_directories, S) ->
    {A, R, N} = scan_files_in_dir(S),
    lists:foreach(fun(F) ->
			  torrent_manager:start_torrent(F)
		  end,
		  sets:to_list(A)),
    lists:foreach(fun(F) -> torrent_manager:stop_torrent(F) end,
		  sets:to_list(R)),
    {noreply, N}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%% Operations

empty_state() -> sets:new().

scan_files_in_dir(S) ->
    Files = filelib:fold_files(S#state.dir, ".*\.torrent", false,
			       fun(F, Accum) ->
				       [F | Accum] end, []),
    FilesSet = sets:from_list(Files),
    Added = sets:subtract(FilesSet, S#state.fileset),
    Removed = sets:subtract(S#state.fileset, FilesSet),
    NewState = S#state{fileset = FilesSet},
    {Added, Removed, NewState}.
