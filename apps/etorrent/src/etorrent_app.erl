%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Top level application entry point.
%% <p>This module is intended to be used by the application module of
%% OTP and not by a user. Its only interesting clal is
%% profile_output/0 which can be used to do profiling.</p>
%% @end
-module(etorrent_app).
-behaviour(application).

-include("etorrent_version.hrl").

%% API
-export([start/0, start/1, stop/0]).

%% Callbacks
-export([start/2, stop/1, prep_stop/1, profile_output/0]).

-ignore_xref([{'prep_stop', 1}, {stop, 0}, {check, 1}]).

-define(RANDOM_MAX_SIZE, 999999999999).

start() ->
    start([]).

start(Config) ->
    load_config(Config),
    {ok, Deps} = application:get_key(etorrent, applications),
    true = lists:all(fun ensure_started/1, Deps),
    application:start(etorrent).

stop() ->
    application:stop(etorrent).

load_config([]) ->
    ok;
load_config([{Key, Val} | Next]) ->
    application:set_env(etorrent, Key, Val),
    load_config(Next).

%% @private
start(_Type, _Args) ->
    consider_profiling(),
    PeerId = generate_peer_id(),
    case etorrent_sup:start_link(PeerId) of
	{ok, Pid} ->
            etorrent_log:init_settings(),
	    ok = etorrent_rlimit:init(),
	    ok = etorrent_memory_logger:add_handler(),
	    ok = etorrent_file_logger:add_handler(),
	    ok = etorrent_callback_handler:add_handler(),
	    case etorrent_config:webui() of
		true -> start_webui();
		false -> ignore
	    end,
	    {ok, Pid};
	{error, Err} ->
	    {error, Err}
    end.

%% Consider if the profiling should be enabled.
consider_profiling() ->
    case etorrent_config:profiling() of
	    true ->
            eprof:start(),
            eprof:start_profiling([self()]);
	    false ->
	        ignore
    end.

%% @doc Output profile information
%% <p>If profiling was enabled, output profile information in
%% "procs.profile" and "total.profile"</p>
%% @end
profile_output() ->
    eprof:stop_profiling(),
    eprof:log("procs.profile"),
    eprof:analyze(procs),
    eprof:log("total.profile"),
    eprof:analyze(total).

%% @private
prep_stop(_S) ->
    io:format("Shutting down etorrent~n"),
    ok.

%% @private
stop(_State) ->
    ok.

start_webui() ->
    Dispatch = [ {'_', [{'_', etorrent_cowboy_handler, []}]} ],
    {ok, _Pid} = cowboy:start_listener(http, 10,
                                       cowboy_tcp_transport, [{port, 8080}],
                                       cowboy_http_protocol, [{dispatch, Dispatch}]
                                      ).
    
%% @doc Generate a random peer id for use
%% @end
generate_peer_id() ->
    Number = crypto:rand_uniform(0, ?RANDOM_MAX_SIZE),
    Rand = io_lib:fwrite("~B----------", [Number]),
    PeerId = lists:flatten(io_lib:format("-ET~s-~12s", [?VERSION, Rand])),
    list_to_binary(PeerId).


ensure_started(App) ->
    case application:start(App) of
        ok ->
            true;
        {error, {already_started, App}} ->
            true;
        Else ->
            error_logger:error_msg("Couldn't start ~p: ~p", [App, Else]),
            Else
    end.
