-module(utp).

-export([
         start/1,
         start_app/1
         ]).

-export([
         test_connector_1/0,
         test_connectee_1/0,
         test_connector_2/0,
         test_connectee_2/0,
         test_connector_3/0,
         test_connectee_3/0,
         test_close_in_1/0,
         test_close_out_1/0,
         test_close_in_2/0,
         test_close_out_2/0,
         test_close_in_3/0,
         test_close_out_3/0,
         test_send_large_file/1,
         test_recv_large_file/1,

         get/1
         ]).

-export([s0/0, r0/0,
         s1/0, r1/0,
         s2/0, r2/0]).

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
    ok = gen_utp:send(Sock, "HELLO"),
    ok = gen_utp:send(Sock, "WORLD").

test_connector_2() ->
    Sock = gen_utp:connect("localhost", 3333),
    {ok, <<"HELLOWORLD">>} = gen_utp:recv(Sock, 10),
    ok.

test_connector_3() ->
    Sock = gen_utp:connect("localhost", 3333),
    ok = gen_utp:send(Sock, "12345"),
    ok = gen_utp:send(Sock, "67890"),
    {ok, <<"HELLOWORLD">>} = gen_utp:recv(Sock, 10),
    ok.

test_close_out_1() ->
    Sock = gen_utp:connect("localhost", 3333),
    ok = gen_utp:close(Sock),
    {error, econnreset} = gen_utp:send(Sock, <<"HELLO">>),
    ok.

test_close_in_1() ->
    gen_utp:listen(),
    {ok, Sock} = gen_utp:accept(),
    timer:sleep(3000),
    {error, econnreset} = gen_utp:recv(Sock, 5),
    ok = gen_utp:close(Sock),
    ok.

test_close_out_2() ->
    Sock = gen_utp:connect("localhost", 3333),
    timer:sleep(3000),
    {error, econnreset} = gen_utp:send(Sock, <<"HELLO">>),
    ok = gen_utp:close(Sock),
    ok.

test_close_in_2() ->
    gen_utp:listen(),
    {ok, Sock} = gen_utp:accept(),
    ok = gen_utp:close(Sock),
    {error, econnreset} = gen_utp:recv(Sock, 5),
    ok.

test_close_out_3() ->
    Sock = gen_utp:connect("localhost", 3333),
    ok = gen_utp:send(Sock, <<"HELLO">>),
    {ok, <<"WORLD">>} = gen_utp:recv(Sock, 5),
    ok = gen_utp:close(Sock),
    ok.

test_close_in_3() ->
    gen_utp:listen(),
    {ok, Sock} = gen_utp:accept(),
    ok = gen_utp:send(Sock, "WORLD"),
    {ok, <<"HELLO">>} = gen_utp:recv(Sock, 5),
    ok = gen_utp:close(Sock),
    ok.

test_connectee_1() ->
    gen_utp:listen(),
    {ok, Port} = gen_utp:accept(),
    {ok, R1} = gen_utp:recv(Port, 5),
    {ok, R2} = gen_utp:recv(Port, 5),
    ok = gen_utp:close(Port),
    {R1, R2}.

test_connectee_2() ->
    gen_utp:listen(),
    {ok, Sock} = gen_utp:accept(),
    ok = gen_utp:send(Sock, <<"HELLO">>),
    ok = gen_utp:send(Sock, <<"WORLD">>),
    ok = gen_utp:close(Sock),
    ok.

test_connectee_3() ->
    gen_utp:listen(),
    {ok, Sock} = gen_utp:accept(),
    ok = gen_utp:send(Sock, <<"HELLO">>),
    ok = gen_utp:send(Sock, <<"WORLD">>),
    {ok, <<"12345">>} = gen_utp:recv(Sock, 5),
    {ok, <<"67890">>} = gen_utp:recv(Sock, 5),
    ok = gen_utp:close(Sock),
    ok.

test_send_large_file(Data) ->
    Sock = gen_utp:connect("localhost", 3333),
    ok = gen_utp:send(Sock, Data),
    ok = gen_utp:close(Sock),
    ok.

test_recv_large_file(Sz) ->
    gen_utp:listen(),
    {ok, Port} = gen_utp:accept(),
    {ok, R} = gen_utp:recv(Port, Sz),
    ok = gen_utp:close(Port),
    R.

get(N) when is_integer(N) ->
    {ok, Sock} = gen_utp:connect("port1394.ds1-vby.adsl.cybercity.dk", 3333),
    ok = gen_utp:send(Sock, <<N:32/integer>>),
    {ok, <<FnLen:32/integer>>} = gen_utp:recv(Sock, 4),
    {ok, FName}        = gen_utp:recv(Sock, FnLen),
    {ok, <<Len:32/integer>>} = gen_utp:recv(Sock, 4),
    {ok, Data} = gen_utp:recv(Sock, Len),
    file:write_file(FName, Data),
    ok = gen_utp:close(Sock),
    ok.

s0() ->
    start_app(3334),
    test_connector_1().

r0() ->
    start_app(3333),
    {<<"HELLO">>, <<"WORLD">>} = test_connectee_1().

s1() ->
    start_app(3334),
    {ok, Data} = file:read_file("test/utp_SUITE_data/test_large_send.dat"),
    test_send_large_file(Data).

r1() ->
    start_app(3333),
    {ok, Data} = file:read_file("test/utp_SUITE_data/test_large_send.dat"),
    Data = test_recv_large_file(byte_size(Data)).

s2() ->
    start_app(3334),
    test_connector_1(),
    test_connector_1().

r2() ->
    start_app(3333),
    {<<"HELLO">>, <<"WORLD">>} = test_connectee_1(),
    {<<"HELLO">>, <<"WORLD">>} = test_connectee_1().












