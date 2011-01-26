%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Various miscellaneous utilities not fitting into other places
%% @end
-module(etorrent_utils).

-ifdef(TEST).
-include_lib("eqc/include/eqc.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API

%% "stdlib-like" functions
-export([gsplit/2, queue_remove/2, group/1,
	 list_shuffle/1, date_str/1]).

%% "time-like" functions
-export([now_subtract_seconds/2]).

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

%% @doc Remove first occurence of Item in queue() if present.
%%   Note: This function assumes the representation of queue is opaque
%%   and thus the function is quite ineffective. We can build a much
%%   much faster version if we create our own queues.
%% @end
-spec queue_remove(term(), queue()) -> queue().
queue_remove(Item, Q) ->
    QList = queue:to_list(Q),
    List = lists:delete(Item, QList),
    queue:from_list(List).

%% @doc Permute List1 randomly. Returns the permuted list.
%%  This functions usage hinges on a seeding of the RNG in Random!
%% @end
-spec list_shuffle([term()]) -> [term()].
list_shuffle(List) ->
    Randomized = lists:sort([{random:uniform(), Item} || Item <- List]),
    [Value || {_, Value} <- Randomized].

%% @doc A Date formatter for {{Y, Mo, D}, {H, Mi, S}}.
%% @end
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
    IP = etorrent_bcoding:get_value("ip", IPDict),
    Port = etorrent_bcoding:get_value("port", IPDict),
    decode_ips(Rest, [{binary_to_list(IP), Port} | Accum]);
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

% @doc Subtract a time delta in millsecs from a now() triple
% @end
-spec now_subtract_seconds({integer(), integer(), integer()}, integer()) ->
    {integer(), integer(), integer()}.
now_subtract_seconds({Megasecs, Secs, Ms}, Subsecs) ->
    case Secs - Subsecs of
        N when N >= 0 ->
            {Megasecs, N, Ms};
        N ->
            Needed = abs(N) div 1000000 + 1,
            {Megasecs - Needed, N + (Needed * 1000000), Ms}
    end.

%%====================================================================

-ifdef(EUNIT).
-ifdef(EQC).

prop_gsplit_split() ->
    ?FORALL({N, Ls}, {nat(), list(int())},
	    if
		N >= length(Ls) ->
		    {Ls, []} =:= gsplit(N, Ls);
		true ->
		    lists:split(N, Ls) =:= gsplit(N, Ls)
	    end).

prop_group_count() ->
    ?FORALL(Ls, list(int()),
	    begin
		Sorted = lists:sort(Ls),
		Grouped = group(Sorted),
		lists:all(
		  fun({Item, Count}) ->
			  length([E || E <- Ls,
				       E =:= Item]) == Count
		  end,
		  Grouped)
	    end).

eqc_test() ->
    ?assert(eqc:quickcheck(prop_group_count())),
    ?assert(eqc:quickcheck(prop_gsplit_split())).

-endif.
-endif.
