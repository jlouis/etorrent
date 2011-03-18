-module(utp).

-export([
         connector/0,
         connectee/0
         ]).

connector() ->
    utp_app:start(3334),
    gen_utp:connect("localhost", 3333).

connectee() ->
    utp_app:start(3333),
    gen_utp:listen(),
    gen_utp:accept().
