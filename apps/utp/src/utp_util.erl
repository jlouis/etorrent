-module(utp_util).

-export([
         bit16/1,
         bit32/1
         ]).

%% @doc `bit16(Expr)' performs `Expr' modulo 65536
%% @end
-spec bit16(integer()) -> integer().
bit16(N) when is_integer(N) ->
    N band 16#FFFF.

-spec bit32(integer()) -> integer().
bit32(N) when is_integer(N) ->
    N band 16#FFFFFFFF.
