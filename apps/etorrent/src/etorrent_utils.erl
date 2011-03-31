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
	 list_shuffle/1, date_str/1, any_to_list/1,
     merge_proplists/2, compare_proplists/2,
     wait/1, expect/1, shutdown/1]).

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

any_to_list(V) when is_list(V) ->
    V;
any_to_list(V) when is_integer(V) ->
    integer_to_list(V);
any_to_list(V) when is_atom(V) ->
    atom_to_list(V);
any_to_list(V) when is_binary(V) ->
    binary_to_list(V).


%% @doc Returns a proplist formed by merging OldProp and NewProp. If a key
%%      presents only in OldProp or NewProp, the tuple is picked. If a key
%%      presents in both OldProp and NewProp, the tuple from NewProp is
%%      picked.
%% @end
-spec merge_proplists(proplists:proplist(), proplists:proplist()) ->
    proplists:proplist().
merge_proplists(OldProp, NewProp) ->
    lists:ukeymerge(1, lists:ukeysort(1, NewProp), lists:ukeysort(1, OldProp)).

%% @doc Returns true if two proplists match regardless of the order of tuples
%%      present in them, false otherwise.
%% @end
-spec compare_proplists(proplists:proplist(), proplists:proplist()) ->
    boolean().
compare_proplists(Prop1, Prop2) ->
    lists:ukeysort(1, Prop1) =:= lists:ukeysort(1, Prop2).

%% @doc Wait for a monitored process to exit
%% @end
-spec wait(reference()) -> ok.
wait(MRef) ->
    receive {'DOWN', MRef, process, _, _} -> ok end.

%% @doc Wait for a message to arrive
%% @end
-spec expect(term()) -> ok.
expect(Message) ->
    receive Message -> ok end.

%% @doc Shutdown a child process
%% @end
-spec shutdown(pid()) -> ok.
shutdown(Pid) ->
    MRef = erlang:monitor(process, Pid),
    unlink(Pid),
    exit(Pid, shutdown),
    wait(MRef).


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

shuffle_list(List) ->
    random:seed(now()),
    {NewList, _} = lists:foldl( fun(_El, {Acc,Rest}) ->
        RandomEl = lists:nth(random:uniform(length(Rest)), Rest),
        {[RandomEl|Acc], lists:delete(RandomEl, Rest)}
    end, {[],List}, List),
    NewList.

proplist_utils_test() ->
    Prop1 = lists:zip(lists:seq(1, 15), lists:seq(1, 15)),
    Prop2 = lists:zip(lists:seq(5, 20), lists:seq(5, 20)),
    PropFull = lists:zip(lists:seq(1, 20), lists:seq(1, 20)),
    ?assertEqual(merge_proplists(shuffle_list(Prop1), shuffle_list(Prop2)),
                 PropFull),
    ?assert(compare_proplists(Prop1, shuffle_list(Prop1))),
    ok.

eqc_count_test_() ->
    %% Run the first eqc-based test with a higher timeout value
    %% beacause it takes time for EQC to authenticate when it's autostarted.
    {timeout, 1000, [?_assert(eqc:quickcheck(prop_group_count()))]}.

eqc_gsplit_test() ->
    ?assert(eqc:quickcheck(prop_gsplit_split())).

-endif.
-endif.







