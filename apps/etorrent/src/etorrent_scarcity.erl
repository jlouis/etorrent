-module(etorrent_scarcity).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([from_list/1,
         to_list/1,
         insert/3,
         delete/2,
         increment/2,
         decrement/2,
         iterator/1,
         next/1]).

-record(scarcity, {
    counters :: array(),
    ordering :: gb_set()}).

-opaque scarcity() :: #scarcity{}.
-export_type([scarcity/0]).
    

%% @doc
%% Return an indexed scarcity list based on the input. The input
%% must be list of piece indexes paired with the numberof peers
%% currently provide a valid copy of the piece.
%% @end
-spec from_list(list({pos_integer(), pos_integer()})) -> scarcity().
from_list(ScarcityList) ->
    [error(badarg) || {I,S} <- ScarcityList, (I < 0) or (S < 0)],
    InitCounters = array:from_orddict(ScarcityList),
    InitOrdering = gb_sets:from_list([{S,I} || {I,S} <- ScarcityList]),
    #scarcity{counters=InitCounters, ordering=InitOrdering}.


%% @doc
%% Returned a list of piece indexes ordered by how many peers are
%% currently provide a valid copy of the piece. The returned list
%% is sorted in increasing order.
%% @end
-spec to_list(#scarcity{}) -> list(pos_integer()).
to_list(Scarcity) ->
    #scarcity{ordering=Ordering} = Scarcity,
    [Index || {_, Index} <- gb_sets:to_list(Ordering)].


%% @doc
%% Insert a new piece with an initial number of providing peers into the
%% scarcity list. The piece index must be larger than or equal to zero.
%% It is up the calling process to check that the piece index is not higher
%% than the number of pieces in the torrent.
%% @end
-spec insert(pos_integer(), pos_integer(), #scarcity{}) -> scarcity().
insert(Index, Count, Scarcity) ->
    #scarcity{counters=Counters, ordering=Ordering} = Scarcity,
    assert_not_member(Index, Counters),
    assert_positive(Count),

    NewCounters = array:set(Index, Count, Counters),
    NewOrdering = gb_sets:insert({Count, Index}, Ordering),

    #scarcity{counters=NewCounters, ordering=NewOrdering}.


%% @doc
%% Delete a piece from the scarcify. The piece must be a member of
%% the scarcity list or the function will throw error(badarg).
%% @end
-spec delete(pos_integer(), #scarcity{}) -> scarcity().
delete(Index, Scarcity) ->
    #scarcity{counters=Counters, ordering=Ordering} = Scarcity,
    assert_member(Index, Counters),

    Count = array:get(Index, Counters),
    NewCounters = array:reset(Index, Counters),
    NewOrdering = gb_sets:delete({Count, Index}, Ordering),

    #scarcity{counters=NewCounters, ordering=NewOrdering}.


%% @doc
%% Increment the number of peers providing a piece by one and
%% reprioritize the pieces in the scarcity list.
%% @end
-spec increment(pos_integer(), #scarcity{}) -> scarcity().
increment(Index, Scarcity) ->
    #scarcity{counters=Counters, ordering=Ordering} = Scarcity,
    assert_member(Index, Counters),

    Count    = array:get(Index, Counters),
    NewCount = Count + 1,
    NewCounters = array:set(Index, NewCount, Counters),
    TmpOrdering = gb_sets:delete({Count, Index}, Ordering),
    NewOrdering = gb_sets:insert({NewCount, Index}, TmpOrdering),

    #scarcity{counters=NewCounters, ordering=NewOrdering}.


%% @doc
%% Decrement the number of peers providing a piece by one and
%% reprioritize the pieces in the scarcity list.
%% @end
-spec decrement(pos_integer(), #scarcity{}) -> scarcity().
decrement(Index, Scarcity) ->
    #scarcity{counters=Counters, ordering=Ordering} = Scarcity,
    assert_member(Index, Counters),

    Count    = array:get(Index, Counters),
    NewCount = Count - 1,
    assert_positive(NewCount),
    NewCounters = array:set(Index, NewCount, Counters),
    TmpOrdering = gb_sets:delete({Count, Index}, Ordering),
    NewOrdering = gb_sets:insert({NewCount, Index}, TmpOrdering),

    #scarcity{counters=NewCounters, ordering=NewOrdering}.


%% @doc
%% Return an iterator that tranverses the pieces in the scarcity
%% list in the same order as the list returned by :to_list/1.
%% @end
-spec iterator(#scarcity{}) -> term().
iterator(Scarcity) ->
    #scarcity{ordering=Ordering} = Scarcity,
    gb_sets:iterator(Ordering).


%% @doc
%% Return the head and tail of an iterator. If the end of the
%% iterator has been reached none is returned.
%% @end
-spec next(term()) -> none | {pos_integer(), term()}.
next(Iterator) ->
    case gb_sets:next(Iterator) of
        none ->
            none;
        {{_, Index}, NewIterator} ->
            {Index, NewIterator}
    end.


%% @doc  
%% Ensure that a piece is a member of the scarcity list.
%% @end
-spec assert_member(pos_integer(), array()) -> ok.
assert_member(Index, Counters) ->
    case array:get(Index, Counters) of
        undefined ->
            error(badarg);
        _  ->
            ok
    end.


%% @doc
%% Ensure that a piece is not a member of the scarcity list.
%% @end
-spec assert_not_member(pos_integer(), array()) -> ok.
assert_not_member(Index, Counters) ->
    case array:get(Index, Counters) of
        undefined ->
            ok;
        _ ->
            error(badarg)
    end.


%% @doc
%% Ensure that a piece index is not negative, it really shouldn't be.
%% @end
-spec assert_positive(pos_integer()) -> ok.
assert_positive(Integer) ->
    case Integer < 0 of
        false ->
            ok;
        true ->
            error(badarg)
    end.


-ifdef(TEST).
-define(mod, ?MODULE).

new_all_unordered_test() ->
    S0 = ?mod:from_list([{0,0},{1,0},{2,0}]),
    ?assertEqual([0,1,2], ?mod:to_list(S0)).

new_all_ordered_test() ->
    S0 = ?mod:from_list([{0,0},{1,1},{2,2}]),
    ?assertEqual([0,1,2], ?mod:to_list(S0)).

new_all_reversed_test() ->
    S0 = ?mod:from_list([{0,2},{1,1},{2,0}]),
    ?assertEqual([2,1,0], ?mod:to_list(S0)).

increment_test() ->
    S0 = ?mod:from_list([{0,0}, {1,1}, {2,2}]),
    S1 = ?mod:increment(0, S0),
    S2 = ?mod:increment(0, S1),
    S3 = ?mod:increment(0, S2),
    S4 = ?mod:increment(0, S3),
    ?assertEqual([1,2,0], ?mod:to_list(S4)).

decrement_test() ->
    S0 = ?mod:from_list([{0,0}, {1,1}, {2,4}]),
    S1 = ?mod:decrement(2, S0),
    S2 = ?mod:decrement(2, S1),
    S3 = ?mod:decrement(2, S2),
    S4 = ?mod:decrement(2, S3),
    ?assertEqual([2,0,1], ?mod:to_list(S4)).

delete_test() ->
    S0 = ?mod:from_list([{0,0},{1,1},{2,2}]),
    S1 = ?mod:delete(0, S0),
    S2 = ?mod:delete(1, S0),
    S3 = ?mod:delete(2, S0),
    ?assertEqual([1,2], ?mod:to_list(S1)),
    ?assertEqual([0,2], ?mod:to_list(S2)),
    ?assertEqual([0,1], ?mod:to_list(S3)).

delete_nonmember_test() ->
    S0 = ?mod:from_list([{0,0},{2,2}]),
    ?assertError(badarg, ?mod:delete(1, S0)).

insert_member_test() ->
    S0 = ?mod:from_list([{0,0},{1,1},{2,2}]),
    ?assertError(badarg, ?mod:insert(1, 1, S0)).

iterator_test() ->
    S0 = ?mod:from_list([{0,0},{2,2}]),
    I0 = ?mod:iterator(S0),
    {E1,I1} = ?mod:next(I0),
    {E2,I2} = ?mod:next(I1),
    ?assertEqual(0, E1),
    ?assertEqual(2, E2),
    ?assertEqual(none, ?mod:next(I2)).

-endif.
