%%%-------------------------------------------------------------------
%%% File    : dirwatcher.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus>
%%% License : See COPYING
%%% Description : Watch a directory for the presence of torrent files.
%%%               Send commands when files are added and removed.
%%%
%%% Created : 24 Jan 2007 by Jesper Louis Andersen <jlouis@succubus>
%%%-------------------------------------------------------------------
-module(etorrent_dirwatcher).
-author("Jesper Louis Andersen <jesper.louis.andersen@gmail.com>").
-behaviour(gen_server).

-vsn("1").
%% API
-export([start_link/0, dir_watched/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {dir = none}).
-define(WATCH_WAIT_TIME, timer:seconds(20)).
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
    _Tid = ets:new(etorrent_dirwatcher, [named_table, protected]),
    {ok, #state{dir = Dir}, 0}.

handle_call(dir_watched, _Who, S) ->
    {reply, S#state.dir, S, ?WATCH_WAIT_TIME};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State, ?WATCH_WAIT_TIME}.

handle_cast(_Request, S) ->
    {noreply, S, ?WATCH_WAIT_TIME}.

handle_info(timeout, S) ->
    watch_directories(S),
    {noreply, S, ?WATCH_WAIT_TIME};
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
    reset_marks(ets:first(etorrent_dirwatcher)),
    lists:foreach(fun process_file/1,
		  filelib:wildcard("*.torrent", S#state.dir)),

    ets:safe_fixtable(etorrent_dirwatcher, true),
    start_stop(ets:first(etorrent_dirwatcher)),
    ets:safe_fixtable(etorrent_dirwatcher, false),
    ok.

process_file(F) ->
    case ets:lookup(etorrent_dirwatcher, F) of
	[] ->
	    ets:insert(etorrent_dirwatcher, {F, new});
	[_] ->
	    ets:insert(etorrent_dirwatcher, {F, marked})
    end.

reset_marks('$end_of_table') -> ok;
reset_marks(Key) ->
    ets:insert(etorrent_dirwatcher, {Key, unmarked}),
    reset_marks(ets:next(etorrent_dirwatcher, Key)).

start_stop('$end_of_table') -> ok;
start_stop(Key) ->
    [{Key, S}] = ets:lookup(etorrent_dirwatcher, Key),
    case S of
	new -> etorrent_mgr:start(Key);
	marked -> ok;
	unmarked -> etorrent_mgr:stop(Key),
		    ets:delete(etorrent_dirwatcher, Key)
    end,
    start_stop(ets:next(etorrent_dirwatcher, Key)).
