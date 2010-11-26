%%%-------------------------------------------------------------------
%%% File    : etorrent_utils.erl
%%% Author  : User Jlouis <jesper.louis.andersen@gmail.com>
%%% License : See COPYING
%%% Description : A selection of utilities used throughout the code
%%%               Should probably be standard library in Erlang some of them
%%%               If a function does not really fit into another module, they
%%%               tend to go here if general enough.
%%%
%%% Created : 17 Apr 2007 by User Jlouis <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_utils).

%% API

%% "stdlib-like" functions
-export([gsplit/2, queue_remove/2, queue_remove_check/2, group/1,
	 shuffle/1, date_str/1]).

%% "bittorrent-like" functions
-export([decode_ips/1]).

%%====================================================================

%% @doc Graceful split.
%% Works like lists:split, but if N is greater than length(L1), then
%% it will return L1 =:= L2 and L3 = []. This will gracefully make it
%% ignore out-of-items situations.
%% @end
-spec gsplit(integer(), [term()]) -> {[term()], [term()]}.
gsplit(N, L) ->
    gsplit(N, L, []).

gsplit(_N, [], Rest) ->
    {lists:reverse(Rest), []};
gsplit(0, L1, Rest) ->
    {lists:reverse(Rest), L1};
gsplit(N, [H|T], Rest) ->
    gsplit(N-1, T, [H | Rest]).

%% @doc Remove items from a queue
%% If Item is present in queue(), remove the first
%% occurence and return it as {ok, Q2}. If the item can not be found
%% return false.
%% Note: Inefficient implementation. Converts to/from lists.
%% @end
-spec queue_remove_check(term(), queue()) -> queue().
queue_remove_check(Item, Q) ->
    QList = queue:to_list(Q),
    true = lists:member(Item, QList),
    List = lists:delete(Item, QList),
    queue:from_list(List).

%% @doc
%% Remove first occurence of Item in queue() if present.
%% Note: This function assumes the representation of queue is opaque
%% and thus the function is quite ineffective. We can build a much
%% much faster version if we create our own queues.
%% @end
-spec queue_remove(term(), queue()) -> queue().
queue_remove(Item, Q) ->
    QList = queue:to_list(Q),
    List = lists:delete(Item, QList),
    queue:from_list(List).

%% @doc Permute List1 randomly. Returns the permuted list.
%%  Implementation error: The shuffle is not fair and should be corrected
%% @end
-spec shuffle([term()]) -> [term()].
shuffle(List) ->
    merge_shuffle(List).

-spec date_str({{integer(), integer(), integer()},
                {integer(), integer(), integer()}}) -> string().
date_str({{Y, Mo, D}, {H, Mi, S}}) ->
    lists:flatten(io_lib:format("~w-~2.2.0w-~2.2.0w ~2.2.0w:"
                                "~2.2.0w:~2.2.0w",
                                [Y,Mo,D,H,Mi,S])).

%% @doc Decode the IP response from the tracker
%% @end
decode_ips(D) ->
    decode_ips(D, []).

decode_ips([], Accum) ->
    Accum;
decode_ips([IPDict | Rest], Accum) ->
    {string, IP} = etorrent_bcoding:search_dict({string, "ip"}, IPDict),
    {integer, Port} = etorrent_bcoding:search_dict({string, "port"},
                                                   IPDict),
    decode_ips(Rest, [{IP, Port} | Accum]);
decode_ips(<<>>, Accum) ->
    Accum;
decode_ips(<<B1:8, B2:8, B3:8, B4:8, Port:16/big, Rest/binary>>, Accum) ->
    decode_ips(Rest, [{{B1, B2, B3, B4}, Port} | Accum]);
decode_ips(_Odd, Accum) ->
    Accum. % This case is to handle wrong tracker returns. Ignore spurious bytes.

%% @doc Group a sorted list
%%  if the input is a sorted list L, the output is [{E, C}] where E is an element
%%  occurring in L and C is a number stating how many times E occurred.
%% @end
group([]) -> [];
group([E | L]) ->
    group(E, 1, L).

group(E, K, []) -> [{E, K}];
group(E, K, [E | R]) -> group(E, K+1, R);
group(E, K, [F | R]) -> [{E, K} | group(F, 1, R)].

%%====================================================================

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


