-module(etorrent_fs_janitor).

-behaviour(gen_server).

-export([start_link/0, fs_maybe_collect/0, bump/1, new_fs_process/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(HIGH, 128).
-define(LOW, 100).
-define(SERVER, ?MODULE).

-record(state, { high, low }).

%% Start a new janitor.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

new_fs_process(Pid) ->
    bump(Pid),
    gen_server:cast(?MODULE, {monitor_me, Pid}),
    fs_maybe_collect().

bump(Pid) ->
    ets:insert(?MODULE, {Pid, erlang:now()}).

%% Check the current number of processes. If there are more than the high watermark,
%% start a resource collection.
fs_maybe_collect() ->
    H = case application:get_env(etorrent, fs_watermark_high) of
            {ok, V} -> V;
            undefined -> ?HIGH
        end,
    Sz = ets:info(?MODULE, size),
    if
        Sz > H ->
            gen_server:cast(?SERVER, fs_collect);
        true -> ignore
    end.

%% =======================================================================

collect_filesystem_processes(LowBound) ->
    Sz = ets:info(?MODULE, size),
    FSPids = lists:keysort(2, ets:match_object(?MODULE, '$1')),
    {ToKill, _} = lists:split(Sz - LowBound, FSPids),
    _ = [etorrent_fs_process:stop(P) || {P, _} <- ToKill],
    ok.

create_tab() ->
    _ = ets:new(?MODULE, [public, named_table]),
    ok.

%% =======================================================================

init([]) ->
    create_tab(),
    process_flag(trap_exit, true),
    H = case application:get_env(etorrent, fs_watermark_high) of
                {ok, HVal} -> HVal;
                undefined -> ?HIGH
        end,
    L = case application:get_env(etorrent, fs_watermark_low) of
                {ok, LVal} -> LVal;
                undefined -> ?LOW
        end,
    {ok, #state { high = H, low = L}}.

handle_cast(fs_collect, S) ->
    collect_filesystem_processes(S#state.low),
    {noreply, S};
handle_cast({monitor_me, Pid}, S) ->
    erlang:monitor(process, Pid),
    {noreply, S};
handle_cast(Other, S) ->
    error_logger:error_report([unknown_msg, Other]),
    {noreply, S}.

handle_call(Other, _From, S) ->
    error_logger:error_report([unknown_msg, Other]),
    {noreply, S}.

handle_info({'DOWN', _, _, Pid, _}, S) ->
    ets:delete(?MODULE, Pid),
    {noreply, S};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, _State) ->
    ets:delete(?MODULE),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

