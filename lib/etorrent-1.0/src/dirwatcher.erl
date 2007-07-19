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
-export([start_link/0, dir_watched/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {dir = none,
	        fileset = none}).
-define(WATCH_WAIT_TIME, 60000).
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

dir_watched() ->
    gen_server:call(dirwatcher, dir_watched).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([]) ->
    {ok, Dir} = application:get_env(etorrent, dir),
    % Provide a timeout in 100 ms to get up fast
    {ok, #state{dir = Dir, fileset = empty_state()}, 100}.

handle_call(report_on_files, _Who, S) ->
    {reply, sets:to_list(S#state.fileset), S, ?WATCH_WAIT_TIME};
handle_call(dir_watched, _Who, S) ->
    {reply, S#state.dir, S, ?WATCH_WAIT_TIME};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State, ?WATCH_WAIT_TIME}.

handle_cast(_Request, S) ->
    {noreply, S, ?WATCH_WAIT_TIME}.

handle_info(timeout, S) ->
    N = watch_directories(S),
    {noreply, N, ?WATCH_WAIT_TIME};
handle_info(_Info, State) ->
    {noreply, State, ?WATCH_WAIT_TIME}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%% Operations
watch_directories(S) ->
    {ok, A, R, N} = scan_files_in_dir(S),
    lists:foreach(fun(F) ->
			  torrent_manager:start_torrent(F)
		  end,
		  sets:to_list(A)),
    lists:foreach(fun(F) -> torrent_manager:stop_torrent(F) end,
		  sets:to_list(R)),
    N.

empty_state() -> sets:new().

scan_files_in_dir(S) ->
    Files = filelib:fold_files(S#state.dir, ".*\.torrent", false,
			       fun(F, Accum) ->
				       [F | Accum] end, []),
    FilesSet = sets:from_list(Files),
    Added = sets:subtract(FilesSet, S#state.fileset),
    Removed = sets:subtract(S#state.fileset, FilesSet),
    NewState = S#state{fileset = FilesSet},
    {ok, Added, Removed, NewState}.
