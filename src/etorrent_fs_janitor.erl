-module(etorrent_fs_janitor).

-behaviour(gen_server).

-export([start_link/0, fs_collect/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(HIGH, 128).
-define(LOW, 100).
-define(SERVER, ?MODULE).

-record(state, { high, low }).

%% Start a new janitor.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

fs_collect() ->
    gen_server:cast(?SERVER, fs_collect).

collect_filesystem_processes() ->
    todo.

create_tab() ->
    ets:new(?MODULE, [public, named_table]).

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
    collect_filesystem_processes(),
    {noreply, S};
handle_cast(Other, S) ->
    error_logger:error_report([unknown_msg, Other]),
    {noreply, S}.

handle_call(Other, _From, S) ->
    error_logger:error_report([unknown_msg, Other]),
    {noreply, S}.

handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

