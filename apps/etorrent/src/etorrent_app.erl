-module(etorrent_app).
-behaviour(application).

-include("etorrent_version.hrl").

-export([start/2, stop/1, prep_stop/1]).


-ignore_xref([{'prep_stop', 1}, {stop, 0}, {check, 1}]).

-define(RANDOM_MAX_SIZE, 999999999999).

%% @doc Application callback.
%% @end
start(_Type, _Args) ->
    PeerId = generate_peer_id(),
    %% DB
    etorrent_mnesia_init:init(),
    etorrent_mnesia_init:wait(),
    case application:get_env(etorrent, webui) of
	{ok, true} ->
	    start_webui();
	{ok, false} ->
	    ignore
    end,
    etorrent_sup:start_link(PeerId).

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
    inets:start(httpd, Config, inets).

logger_dir() ->
    {ok, Val} = application:get_env(etorrent, logger_dir),
    Val.

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
     {bind_address, {127,0,0,1}},
     {server_root, filename:join([logger_dir(), "webui"])},
     {port,8080},
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
