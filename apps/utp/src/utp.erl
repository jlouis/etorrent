-module(utp).

-export([
         start/1,
         start_app/1
         ]).

%% @doc Manual startup of the uTP application
start(Port) ->
    ok = ensure_started([sasl, gproc, crypto]),
    utp_sup:start_link(Port).

start_app(Port) ->
    application:set_env(utp, udp_port, Port),
    ok = ensure_started([sasl, gproc, crypto]),
    application:start(utp).

ensure_started([]) ->
    ok;
ensure_started([App | R]) ->
    case application:start(App) of
	ok ->
	    ensure_started(R);
	{error, {already_started, App}} ->
	    ensure_started(R)
    end.

