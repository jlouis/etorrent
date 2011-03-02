-module(etorrent_scarcity).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([from_list/2,
         to_list/1,
         insert/3,
         delete/2,
         increment/2,
         decrement/2]).

-type pieceset() :: etorrent_pieceset:pieceset().
-type piecelist() :: list(pos_integer()).
-record(scarcity, {
    members  :: pieceset(),
    counters :: array(),
    ordering :: piecelist()}).
-opaque scarcity() :: #scarcity{}.
    

%% @doc
%%
%% @end
-spec from_list(pos_integer(), list({pos_integer(), pos_integer()})) -> scarcity().
from_list(NumPieces, ScarcityList) ->
    InitMembers  = etorrent_pieceset:new(NumPieces),
    InitCounters = array:new([{size, NumPieces}, {default, 0}]),
    InitScarcity = #scarcity{
        members=InitMembers,
        counters=InitCounters,
        ordering=[]},
    lists:foldl(fun({Index, Count}, Acc) ->
        insert(Index, Count, Acc)
    end, InitScarcity, ScarcityList).

%% @doc
%%
%% @end
-spec to_list(#scarcity{}) -> list(pos_integer()).
to_list(Scarcity) ->
    #scarcity{ordering=Ordering} = Scarcity,
    Ordering.


%% @doc
%%
%% @end
-spec insert(pos_integer(), pos_integer(), #scarcity{}) -> scarcity().
insert(Index, Count, Scarcity) ->
    #scarcity{
        members=Members,
        counters=Counters,
        ordering=Ordering} = Scarcity,
    assert_not_member(Index, Members),

    NewMembers  = etorrent_pieceset:insert(Index, Members),
    NewCounters = array:set(Index, Count, Counters),
    IsSmaller   = fun(E) -> array:get(E, Counters) =< Count end,
    {Smaller, Larger} = lists:splitwith(IsSmaller, Ordering),
    NewOrdering = Smaller ++ [Index|Larger],

    NewScarcity = #scarcity{
        members=NewMembers,
        counters=NewCounters,
        ordering=NewOrdering},
    NewScarcity.

%% @doc
%%
%% @end
-spec delete(pos_integer(), #scarcity{}) -> scarcity().
delete(Index, Scarcity) ->
     #scarcity{
        members=Members,
        counters=Counters,
        ordering=Ordering} = Scarcity,
    assert_member(Index, Members),

    NewMembers  = etorrent_pieceset:delete(Index, Members),
    NewCounters = array:reset(Index, Counters),
    NewOrdering = lists:delete(Index, Ordering),

    NewScarcity = #scarcity{
        members=NewMembers,
        counters=NewCounters,
        ordering=NewOrdering},
    NewScarcity.

   


%% @doc
%%
%% @end
-spec increment(pos_integer(), #scarcity{}) -> scarcity().
increment(Index, Scarcity) ->
    #scarcity{
        members=Members,
        counters=Counters,
        ordering=Ordering} = Scarcity,
    assert_member(Index, Members),

    PrevCount = array:get(Index, Counters),
    NewCounters = array:set(Index, PrevCount + 1, Counters),
    NewOrdering = reorder(Index, NewCounters, Ordering),

    NewScarcity = #scarcity{
        counters=NewCounters,
        ordering=NewOrdering},
    NewScarcity.


%% @doc
%%
%% @end
-spec decrement(pos_integer(), #scarcity{}) -> scarcity().
decrement(Index, Scarcity) ->
     #scarcity{
        members=Members,
        counters=Counters,
        ordering=Ordering} = Scarcity,
    assert_member(Index, Members),

    PrevCount = array:get(Index, Counters),
    NewCounters = array:set(Index, PrevCount - 1, Counters),
    NewOrdering = reorder(Index, NewCounters, Ordering),

    NewScarcity = #scarcity{
        counters=NewCounters,
        ordering=NewOrdering},
    NewScarcity.

   

%% @doc  
%%
%% @end
-spec assert_member(pos_integer(), pieceset()) -> ok.
assert_member(Index, Pieceset) ->
    case etorrent_pieceset:is_member(Index, Pieceset) of
        true  -> ok;
        false -> error(badarg)
    end.

%% @doc
%%
%% @end
-spec assert_not_member(pos_integer(), pieceset()) -> ok.
assert_not_member(Index, Pieceset) ->
    case etorrent_pieceset:is_member(Index, Pieceset) of
        true  -> error(badarg);
        false -> ok
    end.


%% @doc
%%
%% @end
-spec reorder(pos_integer(), array(), piecelist()) -> piecelist().
%% Changed piece occurs at the middle of the list
reorder(Changed, Counters, [Smaller,Changed,Larger|T]=Original) ->
    SmallerHas = array:get(Smaller, Counters),
    ChangedHas = array:get(Changed, Counters),
    LargerHas  = array:get(Larger,  Counters),
    if  ChangedHas < SmallerHas ->
            [Changed,Smaller,Larger|T];
        ChangedHas > LargerHas ->
            [Smaller,Larger,Changed|T];
        true ->
            Original
    end;
%% Changed piece occurs at the beginning of the list
reorder(Changed, Counters, [Changed,Larger|T]=Original) ->
    ChangedHas = array:get(Changed, Counters),
    LargerHas  = array:get(Larger,  Counters),
    if  ChangedHas > LargerHas ->
            [Larger,Changed|T];
        true ->
            Original
    end;
%% Changed piece occurs at the end of the list
reorder(Changed, Counters, [Smaller,Changed|T]=Original) ->
    ChangedHas = array:get(Changed, Counters),
    SmallerHas = array:get(Smaller, Counters),
    if  ChangedHas < SmallerHas ->
            [ChangedHas,SmallerHas|T];
        true ->
            Original
    end;
%% Not there yet, order of head is unaffected
reorder(Changed, Counters, [H|T]) ->
    [H|reorder(Changed, Counters, T)].

-ifdef(TEST).
-define(mod, ?MODULE).
-define(pset, etorrent_pieceset).

new_all_unordered_test() ->
    New = ?mod:from_list(3, [{0,0},{1,0},{2,0}]),
    ?assertEqual([0,1,2], ?mod:to_list(New)).

new_all_ordered_test() ->
    New = ?mod:from_list(3, [{0,0},{1,1},{2,2}]),
    ?assertEqual([0,1,2], ?mod:to_list(New)).

new_all_reversed_test() ->
    New = ?mod:from_list(3, [{0,2},{1,1},{2,0}]),
    ?assertEqual([2,1,0], ?mod:to_list(New)).

-endif.
