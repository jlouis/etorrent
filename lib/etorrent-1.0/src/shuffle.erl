%%%-------------------------------------------------------------------
%%% File    : shuffle.erl
%%% Author  : User Jlouis <jlouis@succubus.localdomain>
%%% Description : Shuffle a list of items via a merge shuffle
%%%
%%% Created : 31 Jan 2007 by User Jlouis <jlouis@succubus.localdomain>
%%%-------------------------------------------------------------------
-module(shuffle).

%% API
-export([shuffle/1]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: shuffle(List)
%% Description: shuffles the list randomly
%%--------------------------------------------------------------------
shuffle(List) ->
    merge_shuffle(List).

%%====================================================================
%% Internal functions
%%====================================================================
flip_coin() ->
    random:uniform(2) - 1.

merge(A, []) ->
    A;
merge([], B) ->
    B;
merge([A | As], [B | Bs]) ->
    case flip_coin() of
	0 ->
	    [A | merge(As, [B | Bs])];
	1 ->
	    [B | merge([A | As], Bs)]
    end.

partition(List) ->
    partition_l(List, [], []).

partition_l([], A, B) ->
    {A, B};
partition_l([Item], A, B) ->
    {B, [Item | A]};
partition_l([Item | Rest], A, B) ->
    partition_l(Rest, B, [Item | A]).

merge_shuffle([]) ->
    [];
merge_shuffle([Item]) ->
    [Item];
merge_shuffle(List) ->
    {A, B} = partition(List),
    merge(merge_shuffle(A), merge_shuffle(B)).
