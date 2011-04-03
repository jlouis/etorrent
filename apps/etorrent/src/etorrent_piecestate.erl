-module(etorrent_piecestate).
%% This module provides a common interface for processes
%% handling piece state changes.

-export([stored/2,
         valid/2]).

%% @doc
%% @end
-spec stored(non_neg_integer(), pid()) -> ok.
stored(Piece, Srvpid) ->
    Srvpid ! {piece, {stored, Piece}},
    ok.


%% @doc
%% @end
-spec valid(non_neg_integer(), pid()) -> ok.
valid(Piece, Srvpid) ->
    Srvpid ! {piece, {valid, Piece}},
    ok.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(piecestate, ?MODULE).

stored_test() ->
    ?assertEqual(ok, ?piecestate:stored(0, self())),
    ?assertEqual({piece, {stored, 0}}, etorrent_utils:first()).

valid_test() ->
    ?assertEqual(ok, ?piecestate:valid(0, self())),
    ?assertEqual({piece, {valid, 0}}, etorrent_utils:first()).

-endif.
