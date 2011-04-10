-module(etorrent_piecestate).
%% This module provides a common interface for processes
%% handling piece state changes.

-export([unassigned/2,
         stored/2,
         valid/2]).

-type pieceindex() :: etorrent_types:pieceindex().

%% @doc
%% @end
-spec unassigned(pieceindex(), pid()) -> ok.
unassigned(Piece, Srvpid) ->
    Srvpid ! {piece, {unassigned, Piece}},
    ok.


%% @doc
%% @end
-spec stored(pieceindex(), pid()) -> ok.
stored(Piece, Srvpid) ->
    Srvpid ! {piece, {stored, Piece}},
    ok.


%% @doc
%% @end
-spec valid(pieceindex(), pid()) -> ok.
valid(Piece, Srvpid) ->
    Srvpid ! {piece, {valid, Piece}},
    ok.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(piecestate, ?MODULE).

unassigned_test() ->
    ?assertEqual(ok, ?piecestate:unassigned(0, self())),
    ?assertEqual({piece, {unassigned, 0}}, etorrent_utils:first()).

stored_test() ->
    ?assertEqual(ok, ?piecestate:stored(0, self())),
    ?assertEqual({piece, {stored, 0}}, etorrent_utils:first()).

valid_test() ->
    ?assertEqual(ok, ?piecestate:valid(0, self())),
    ?assertEqual({piece, {valid, 0}}, etorrent_utils:first()).

-endif.
