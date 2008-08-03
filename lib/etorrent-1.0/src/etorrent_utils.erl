%%%-------------------------------------------------------------------
%%% File    : etorrent_utils.erl
%%% Author  : User Jlouis <jesper.louis.andersen@gmail.com>
%%% License : See COPYING
%%% Description : A selection of utilities used throughout the code
%%%
%%% Created : 17 Apr 2007 by User Jlouis <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_utils).

%% API
-export([queue_remove/2, queue_remove_check/2,
	 build_encoded_form_rfc1738/1, shuffle/1, gsplit/2]).

%%====================================================================
%% API
%%====================================================================

%%--------------------------------------------------------------------
%% Function: gsplit(N, L1) -> {L2, L3}
%% Description:
%%    types: N          - integer()
%%           L1, L2, L3 - list()
%%
%%   Graceful split. Works is lists:split, but if N is greater than
%%     length(L1) then L1 =:= L2 and L3 = []
%%--------------------------------------------------------------------
gsplit(N, L) ->
    gsplit(N, L, []).

gsplit(_N, [], Rest) ->
    {lists:reverse(Rest), []};
gsplit(0, L1, Rest) ->
    {lists:reverse(Rest), L1};
gsplit(N, [H|T], Rest) ->
    gsplit(N-1, T, [H | Rest]).

%%--------------------------------------------------------------------
%% Function: queue_remove_with_check(Item, Q1) -> {ok, Q2} | false
%% Description: If Item is present in queue(), remove the first
%%   occurence and return it as {ok, Q2}. If the item can not be found
%%   return false.
%%   Note: Inefficient implementation. Converts to/from lists.
%%--------------------------------------------------------------------
queue_remove_check(Item, Q) ->
    QList = queue:to_list(Q),
    true = lists:member(Item, QList),
    List = lists:delete(Item, QList),
    queue:from_list(List).

%%--------------------------------------------------------------------
%% Function: queue_remove(Item, queue()) -> queue()
%% Description: Remove first occurence of Item in queue() if present.
%%   Note: This function assumes the representation of queue is opaque
%%     and thus the function is quite ineffective. We can build a much
%%     much faster version if we create our own queues.
%%--------------------------------------------------------------------
queue_remove(Item, Q) ->
    QList = queue:to_list(Q),
    List = lists:delete(Item, QList),
    queue:from_list(List).

%%--------------------------------------------------------------------
%% Function: build_encoded_form_rfc1738(list() | binary()) -> String
%% Description: Convert the list into RFC1738 encoding (URL-encoding).
%%--------------------------------------------------------------------
build_encoded_form_rfc1738(List) when is_list(List) ->
    Unreserved = rfc_3986_unreserved_characters_set(),
    F = fun (E) ->
		case sets:is_element(E, Unreserved) of
		    true ->
			E;
		    false ->
			lists:concat(
			  ["%", io_lib:format("~2.16.0B", [E])])
		end
	end,
    lists:flatten([F(E) || E <- List]);
build_encoded_form_rfc1738(Binary) when is_binary(Binary) ->
    build_encoded_form_rfc1738(binary_to_list(Binary)).

%%--------------------------------------------------------------------
%% Function: shuffle(List1) -> List2
%% Description: Permute List1 randomly. Returns the permuted list.
%%--------------------------------------------------------------------
shuffle(List) ->
    merge_shuffle(List).

%%====================================================================
%% Internal functions
%%====================================================================

rfc_3986_unreserved_characters() ->
    % jlouis: I deliberately killed ~ from the list as it seems the Mainline
    %  client doesn't announce this.
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_./".

rfc_3986_unreserved_characters_set() ->
    sets:from_list(rfc_3986_unreserved_characters()).

%%
%% Flip a coin randomly
flip_coin() ->
    random:uniform(2) - 1.

%%
%% Merge 2 lists, using a coin flip to choose which list to take the next element from.
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

%%
%% Partition a list into items.
partition(List) ->
    partition_l(List, [], []).

partition_l([], A, B) ->
    {A, B};
partition_l([Item], A, B) ->
    {B, [Item | A]};
partition_l([Item | Rest], A, B) ->
    partition_l(Rest, B, [Item | A]).

%%
%% Shuffle a list by partitioning it and then merging it back by coin-flips
merge_shuffle([]) ->
    [];
merge_shuffle([Item]) ->
    [Item];
merge_shuffle(List) ->
    {A, B} = partition(List),
    merge(merge_shuffle(A), merge_shuffle(B)).






