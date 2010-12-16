%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Watch a directory for presence of torrent files.
%% <p>This module implements a periodic mark'n'sweep over the watched
%% directory and reports upwards any added or removed file.</p>
%% @end
-module(etorrent_dirwatcher).
-author("Jesper Louis Andersen <jesper.louis.andersen@gmail.com>").
-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {dir = none}).
-define(WATCH_WAIT_TIME, timer:seconds(20)).
-define(SERVER, ?MODULE).

-ignore_xref([{start_link, 0}]).
%%====================================================================

%% @doc Starts the dirwatcher process.
%% @end
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


%%====================================================================

%% @doc Watch directories for changes.
%% Watch directories will look through the directory we are watching
%% and will start and stop torrents according to what is inside the
%% directory.
%%
%% The process used is a mark and sweep strategy: First all entries
%% inthe ETS table is made unmarked. Then we process through the files
%% adding new keys or marking keys as we go along with process_file/1.
%% Finally, a Sweep is used to start and stop torrents according to
%% their markings.
%% @end
watch_directories(S) ->
    reset_marks(ets:first(etorrent_dirwatcher)),
    lists:foreach(fun mark/1,
                  filelib:wildcard("*.torrent", S#state.dir)),
    sweep(ets:first(etorrent_dirwatcher)),
    ok.

mark(F) ->
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

sweep('$end_of_table') -> ok;
sweep(Key) ->
    Next = ets:next(etorrent_dirwatcher, Key),
    [{Key, S}] = ets:lookup(etorrent_dirwatcher, Key),
    case S of
        new -> etorrent_mgr:start(Key);
        marked -> ok;
        unmarked -> etorrent_mgr:stop(Key),
                    ets:delete(etorrent_dirwatcher, Key)
    end,
    sweep(Next).

%%====================================================================

%% @private
init([]) ->
    {ok, Dir} = application:get_env(etorrent, dir),
    _Tid = ets:new(etorrent_dirwatcher, [named_table, private]),
    {ok, #state{dir = Dir}, 0}.

%% @private
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State, ?WATCH_WAIT_TIME}.

%% @private
handle_cast(_Request, S) ->
    {noreply, S, ?WATCH_WAIT_TIME}.

%% @private
handle_info(timeout, S) ->
    watch_directories(S),
    {noreply, S, ?WATCH_WAIT_TIME};
handle_info(_Info, State) ->
    {noreply, State, ?WATCH_WAIT_TIME}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
