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

-export([s0/0, r0/0,
         s/0, r/0]).

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

test_send_large_file(Data) ->
    Sock = gen_utp:connect("localhost", 3333),
    gen_utp:send(Sock, Data).

test_recv_large_file(Sz) ->
    gen_utp:listen(),
    {ok, Port} = gen_utp:accept(),
    {ok, R} = gen_utp:recv(Port, Sz),
    R.

s0() ->
    start_app(3334),
    test_connector_1().

r0() ->
    start_app(3333),
    test_connectee_1().

s() ->
    start_app(3334),
    {ok, Data} = file:read_file("test/utp_SUITE_data/test_large_send.dat"),
    test_send_large_file(Data).

r() ->
    start_app(3333),
    {ok, Data} = file:read_file("test/utp_SUITE_data/test_large_send.dat"),
    Data = test_recv_large_file(byte_size(Data)).

