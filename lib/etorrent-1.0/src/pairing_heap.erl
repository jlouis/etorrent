%%%-------------------------------------------------------------------
%%% File    : pairing_heap.erl
%%% Author  : User Jlouis <jlouis@succubus.localdomain>
%%% License : See COPYING
%%% Description : A Pairing Heap implementation.
%%%
%%% Created :  3 Feb 2007 by User Jlouis <jlouis@succubus.localdomain>
%%%-------------------------------------------------------------------
-module(pairing_heap).

%% API
-export([new/0, is_pairing_heap/1, find_max/1, extract_max/1,
	 insert/3, is_empty/1]).

%%====================================================================
%% API
%%====================================================================
new() ->
    {pairing_heap, empty}.

%% -------------------------------------------------------------------
%% Function: is_pairing_heap(heap()) -> true | false
%% Description: pairing heap predicate
%% -------------------------------------------------------------------
is_empty({pairing_heap, H}) ->
    heap_is_empty(H).

%% -------------------------------------------------------------------
%% Function: is_pairing_heap(heap()) -> true | false
%% Description: pairing heap predicate
%% -------------------------------------------------------------------
is_pairing_heap({pairing_heap, _}) ->
    true;
is_pairing_heap(_) ->
    false.

%% -------------------------------------------------------------------
%% Function: find_max(heap()) -> {ok, Priority, Elem} | empty
%% Description: Find the maximum heap element.
%% -------------------------------------------------------------------
find_max({pairing_heap, H}) ->
    heap_find_max(H).

%% -------------------------------------------------------------------
%% Function: extract_max(heap()) -> {ok, Priority, Elem, H} | empty
%% Description: Find the maximum heap element.
%% -------------------------------------------------------------------
extract_max({pairing_heap, H}) ->
    case heap_extract_max(H) of
	empty ->
	    empty;
	{ok, E, P, NH} ->
	    {ok, E, P, {pairing_heap, NH}}
    end.

%% -------------------------------------------------------------------
%% Function: insert(Element, Priority, heap()) -> heap()
%% Description: Insert Element with given Priority into a heap.
%% -------------------------------------------------------------------
insert(E, P, {pairing_heap, H}) ->
    {ok, NH} = heap_insert(E, P, H),
    {pairing_heap, NH}.

%%====================================================================
%% Internal functions
%%====================================================================

%% These functions are mostly a basic implementation of pairing heaps
%% without the {pairing_heap, ...} tag.

heap_extract_max(H) ->
    case H of
	empty ->
	    empty;
	{node, E, P, Cs} ->
	    {ok, E, P, heap_mergify(Cs)}
    end.

heap_find_max(H) ->
    case H of
	empty ->
	    empty;
	{node, E, P, _} ->
	    {ok, E, P}
    end.

heap_is_empty(H) ->
    case H of
	empty ->
	    true;
	_ ->
	    false
    end.

heap_singleton(E, P) ->
    {node, E, P, []}.

heap_insert(E, P, H) ->
    heap_merge(heap_singleton(E, P), H).

heap_merge(empty, H) ->
    H;
heap_merge(H, empty) ->
    H;
heap_merge({node, E1, P1, C1},
	   {node, E2, P2, C2}) ->
    if
	P1 > P2 ->
	    {node, E1, P2, [{node, E2, P2, C2} | C1]};
	true ->
	    {node, E2, P2, [{node, E1, P1, C1} | C2]}
    end.

heap_mergify([]) ->
    empty;
heap_mergify([H1]) ->
    H1;
heap_mergify([H1, H2 | Rest]) ->
    NH = heap_merge(H1, H2),
    heap_merge(NH, heap_mergify(Rest)).

