-module(etorrent_app).
-behaviour(application).

-include("etorrent_version.hrl").

-export([start/2, stop/1, prep_stop/1, profile_output/0]).


-ignore_xref([{'prep_stop', 1}, {stop, 0}, {check, 1}]).

-define(RANDOM_MAX_SIZE, 999999999999).

%% @doc Application callback.
%% @end
start(_Type, _Args) ->
    PeerId = generate_peer_id(),
    %% DB
    case etorrent_config:webui() of
	    true -> start_webui();
	    false -> ignore
    end,
    consider_profiling(),
    case etorrent_sup:start_link(PeerId) of
	{ok, Pid} ->
	    ok = etorrent_memory_logger:add_handler(),
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

profile_output() ->
    eprof:stop_profiling(),
    eprof:log("procs.profile"),
    eprof:analyze(procs),
    eprof:log("total.profile"),
    eprof:analyze(total).

%% @doc Application callback.
%% @end
prep_stop(_S) ->
    io:format("Shutting down etorrent~n"),
    ok.

%% @doc Application callback.
%% @end
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
