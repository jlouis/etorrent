%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Top level application entry point.
%% <p>This module is intended to be used by the application module of
%% OTP and not by a user. Its only interesting clal is
%% profile_output/0 which can be used to do profiling.</p>
%% @end
-module(etorrent_app).
-behaviour(application).

-include("etorrent_version.hrl").

-export([start/0, start/1, start/2, stop/1, prep_stop/1, profile_output/0]).

-ignore_xref([{'prep_stop', 1}, {stop, 0}, {check, 1}]).

-define(RANDOM_MAX_SIZE, 999999999999).

start() ->
    start([]).

start(Config) ->
    load_config(Config),
    ensure_started([inets, crypto, sasl, gproc]),
    application:start(etorrent).

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
	{profiling, true} ->
            eprof:start(),
            eprof:start_profiling([self()]);
	{profiling, false} ->
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
    Config = default_webui_configuration(),
    {ok, _Pid} = inets:start(httpd, Config, inets).

default_webui_configuration() ->
    [{modules,
      [mod_alias,
       mod_auth,
       mod_esi,
       mod_actions,
       mod_cgi,
       mod_dir,
       mod_get,
       mod_head,
       mod_log,
       mod_disk_log]},
     {mime_types, [{"html", "text/html"},
		   {"css", "text/css"},
		   {"js", "text/javascript"}]},
     {server_name,"etorrent_webui"},
     {bind_address, etorrent_config:webui_address()},
     {server_root,  etorrent_config:webui_log_dir()},
     {port,         etorrent_config:webui_port()},
     {document_root, filename:join([code:priv_dir(etorrent), "webui", "htdocs"])},
     {directory_index, ["index.html"]},
     {erl_script_alias, {"/ajax", [etorrent_webui]}},
     {error_log, "error.log"},
     {security_log, "security.log"},
     {transfer_log, "transfer.log"}].

%% @doc Generate a random peer id for use
%% @end
generate_peer_id() ->
    Number = crypto:rand_uniform(0, ?RANDOM_MAX_SIZE),
    Rand = io_lib:fwrite("~B----------", [Number]),
    lists:flatten(io_lib:format("-ET~s-~12s", [?VERSION, Rand])).

ensure_started([]) ->
    ok;
ensure_started([App | R]) ->
    case application:start(App) of
	ok ->
	    ensure_started(R);
	{error, {already_started, App}} ->
	    ensure_started(R)
    end.

