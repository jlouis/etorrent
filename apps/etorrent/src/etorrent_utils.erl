%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Various miscellaneous utilities not fitting into other places
%% @end
-module(etorrent_utils).

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API

%% "stdlib-like" functions
-export([gsplit/2, queue_remove/2, group/1,
	 list_shuffle/1, date_str/1, any_to_list/1,
     merge_proplists/2, compare_proplists/2,
     find/2, wait/1, expect/1, shutdown/1, ping/1,
     first/0]).

%% "mock-like" functions
-export([reply/1]).

%% "time-like" functions
-export([now_subtract_seconds/2]).

%% "bittorrent-like" functions
-export([decode_ips/1]).

%% "registry-like" functions
-export([register/1,
         register_member/1,
         unregister/1,
         unregister_member/1,
         lookup/1,
         lookup_members/1,
         await/1,
         await/2]).

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
-spec wait(reference() | pid) -> ok.
wait(MRef) when is_reference(MRef) ->
    receive {'DOWN', MRef, process, _, _} -> ok end;

wait(Pid) when is_pid(Pid) ->
    MRef = erlang:monitor(process, Pid),
    wait(MRef).


%% @doc Wait for a message to arrive
%% @end
-spec expect(term()) -> ok.
expect(Message) ->
    receive Message -> ok end.

%% @doc Return the first message from the inbox
%% @end
-spec first() -> term().
first() ->
    receive Message -> Message end.


%% @doc Shutdown a child process
%% @end
-spec shutdown(pid()) -> ok.
shutdown(Pid) ->
    MRef = erlang:monitor(process, Pid),
    unlink(Pid),
    exit(Pid, shutdown),
    wait(MRef).

%% @doc Ensure that a previous message has been handled
%% @end
-spec ping(pid() | [pid()]) -> ok.
ping(Pid) when is_pid(Pid) ->
    {status, Pid, _, _} = sys:get_status(Pid),
    ok;

ping(Pids) ->
    [ping(Pid) || Pid <- Pids],
    ok.


%% @doc Handle a gen_server call using a function
%% @end
-spec reply(fun((term()) -> term())) -> ok.
reply(Handler) ->
    receive {'$gen_call', Client, Call} ->
        gen_server:reply(Client, Handler(Call))
    end.


%% @doc Return the first element in the list that matches a condition
%% If no element matched the condition 'false' is returned.
%% @end
-spec find(fun((term()) -> boolean()), [term]) -> false | term().
find(_, []) ->
    false;

find(Condition, [H|T]) ->
    case Condition(H) of
        true  -> H;
        false -> find(Condition, T)
    end.
    

%% @doc Register the local process under a local name
%% @end
-spec register(tuple()) -> true.
register(Name) ->
    gproc:add_local_name(Name).

%% @doc Register the local process as a member of a group
%% @end
-spec register_member(tuple()) -> true.
register_member(Group) ->
    gproc:reg({p, l, Group}, member).


%% @doc Unregister the local process from a name
%% @end
-spec unregister(tuple()) -> true.
unregister(Name) ->
    gproc:unreg({n, l, Name}).

%% @doc Unregister the local process as a member of a group
%% @end
-spec unregister_member(tuple()) -> true.
unregister_member(Group) ->
    gproc:unreg({p, l, Group}).


%% @doc Resolve a local name to a pid
%% @end
-spec lookup(tuple()) -> pid().
lookup(Name) ->
    gproc:lookup_pid({n, l, Name}).

%% @doc Lookup the process id's of all members of a group
%% @end
-spec lookup_members(tuple()) -> [pid()].
lookup_members(Group) ->
    gproc:lookup_pids({p, l, Group}).


%% @doc Wait until a process registers under a local name
%% @end
-spec await(tuple()) -> pid().
await(Name) ->
    await(Name, 5000).

-spec await(tuple(), non_neg_integer()) -> pid().
await(Name, Timeout) ->
    {Pid, undefined} = gproc:await({n, l, Name}, Timeout),
    Pid.




%%====================================================================

-ifdef(EUNIT).
-define(utils, ?MODULE).

find_nomatch_test() ->
    False = fun(_) -> false end,
    ?assertEqual(false, ?utils:find(False, [1,2,3])).

find_match_test() ->
    Last = fun(E) -> E == 3 end,
    ?assertEqual(3, ?utils:find(Last, [1,2,3])).

reply_test() ->
    Pid = spawn_link(fun() ->
        ?utils:reply(fun(call) -> reply end)
    end),
    ?assertEqual(reply, gen_server:call(Pid, call)).

register_test_() ->
    {setup,
        fun() -> application:start(gproc) end,
        fun(_) -> application:stop(gproc) end,
    [?_test(test_register()),
     ?_test(test_register_group())
    ]}.

test_register() ->
    true = ?utils:register(name),
    ?assertEqual(self(), ?utils:lookup(name)),
    ?assertEqual(self(), ?utils:await(name)).

test_register_group() ->
    ?assertEqual([], ?utils:lookup_members(group)),
    true = ?utils:register_member(group),
    ?assertEqual([self()], ?utils:lookup_members(group)),
    Main = self(),
    Pid = spawn_link(fun() ->
        ?utils:register_member(group),
        Main ! registered,
        ?utils:expect(die)
    end),
    ?utils:expect(registered),
    ?assertEqual([self(),Pid], lists:sort(?utils:lookup_members(group))),
    ?utils:unregister_member(group),
    ?assertEqual([Pid], ?utils:lookup_members(group)),
    Pid ! die, ?utils:wait(Pid),
    ?utils:ping(whereis(gproc)),
    ?assertEqual([], ?utils:lookup_members(group)).


-ifdef(PROPER).

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

eqc_count_test() ->
    ?assert(proper:quickcheck(prop_group_count())).

eqc_gsplit_test() ->
    ?assert(proper:quickcheck(prop_gsplit_split())).

-endif.
-endif.
