-module(utp).

-export([
         connector/0,
         connectee/0
         ]).

connector() ->
    utp_app:start(3334),
    utp_gen:connect("localhost", 3333).

connectee() ->
    utp_app:start(3333),
    utp_gen:listen(),
    utp_gen:accept().
