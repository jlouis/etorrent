-module(etorrent_piecestate).
%% This module provides a common interface for processes
%% handling piece state changes.

-export([invalid/2,
         unassigned/2,
         stored/2,
         valid/2]).

-type pieceindex() :: etorrent_types:piece_index().
-type pieces() :: [pieceindex()] | pieceindex().
-type pids() :: [pid()] | pid().


%% @doc
%% @end
-spec invalid(pieces(), pids()) -> ok.
invalid(Pieces, Pids) ->
    notify(Pieces, invalid, Pids).


%% @doc
%% @end
-spec unassigned(pieces(), pids()) -> ok.
unassigned(Pieces, Pids) ->
    notify(Pieces, unassigned, Pids).


%% @doc
%% @end
-spec stored(pieces(), pids()) -> ok.
stored(Pieces, Pids) ->
    notify(Pieces, stored, Pids).


%% @doc
%% @end
-spec valid(pieces(), pids()) -> ok.
valid(Pieces, Pids) ->
    notify(Pieces, valid, Pids).

notify(Pieces, Status, Pid) when is_list(Pieces) ->
    [notify(Piece, Status, Pid) || Piece <- Pieces],
    ok;
notify(Piece, Status, Pids) when is_list(Pids) ->
    [notify(Piece, Status, Pid) || Pid <- Pids],
    ok;
notify(Piece, Status, Pid) ->
    Pid ! {piece, {Status, Piece}},
    ok.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(piecestate, ?MODULE).

%% @todo reuse
flush() ->
    {messages, Msgs} = erlang:process_info(self(), messages),
    [receive Msg -> Msg end || Msg <- Msgs].

piecestate_test_() ->
    {foreach,local,
        fun() -> flush() end,
        fun(_) -> flush() end,
        [?_test(test_notify_pid_list()),
         ?_test(test_notify_piece_list()),
         ?_test(test_invalid()),
         ?_test(test_unassigned()),
         ?_test(test_stored()),
         ?_test(test_valid())]}.

test_notify_pid_list() ->
    ?assertEqual(ok, ?piecestate:invalid(0, [self(), self()])),
    ?assertEqual({piece, {invalid, 0}}, etorrent_utils:first()),
    ?assertEqual({piece, {invalid, 0}}, etorrent_utils:first()).

test_notify_piece_list() ->
    ?assertEqual(ok, ?piecestate:invalid([0,1], self())),
    ?assertEqual({piece, {invalid, 0}}, etorrent_utils:first()),
    ?assertEqual({piece, {invalid, 1}}, etorrent_utils:first()).

test_invalid() ->
    ?assertEqual(ok, ?piecestate:invalid(0, self())),
    ?assertEqual({piece, {invalid, 0}}, etorrent_utils:first()).

test_unassigned() ->
    ?assertEqual(ok, ?piecestate:unassigned(0, self())),
    ?assertEqual({piece, {unassigned, 0}}, etorrent_utils:first()).

test_stored() ->
    ?assertEqual(ok, ?piecestate:stored(0, self())),
    ?assertEqual({piece, {stored, 0}}, etorrent_utils:first()).

test_valid() ->
    ?assertEqual(ok, ?piecestate:valid(0, self())),
    ?assertEqual({piece, {valid, 0}}, etorrent_utils:first()).

-endif.
