-module(utp).

-export([
         start/1,
         start_app/1
         ]).

-export([
         test_connector_1/0,
         test_connectee_1/0,
         test_send_large_file/1,
         test_recv_large_file/1
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

test_connector_1() ->
    Sock = gen_utp:connect("localhost", 3333),
    gen_utp:send(Sock, "HELLO"),
    gen_utp:send(Sock, "WORLD").

test_connectee_1() ->
    gen_utp:listen(),
    {ok, Port} = gen_utp:accept(),
    {ok, R1} = gen_utp:recv(Port, 5),
    {ok, R2} = gen_utp:recv(Port, 5),
    {R1, R2}.

test_send_large_file(_File) ->
    todo.

test_recv_large_file(_File) ->
    todo.







