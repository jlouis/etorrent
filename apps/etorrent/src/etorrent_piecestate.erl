-module(etorrent_piecestate).
%% This module provides a common interface for processes
%% handling piece state changes.

-export([valid/2]).

%% @doc
%% @end
valid(Piece, Srvpid) ->
    Srvpid ! {piece, {valid, Piece}},
    ok.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(piecestate, ?MODULE).

valid_test() ->
    ?assertEqual(ok, ?piecestate:valid(0, self())),
    ?assertEqual({piece, {valid, 0}}, etorrent_utils:first()).

-endif.
