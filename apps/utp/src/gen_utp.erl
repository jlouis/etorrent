-module(gen_utp).

-export([create/1, connect/1, send/2, recv/1, recv/2]).


create(_Port) ->
    todo.

connect(_Sock) ->
    todo.

send(_Socket, _Msg) ->
    todo.

recv(Socket) ->
    recv(Socket, infinity).

recv(_Socket, _Timeout) ->
    todo.

