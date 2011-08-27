-module(rlimit).
%% This module implements an RED strategy layered on top of a token bucket
%% for shaping a message flow down to a user defined rate limit. Each message
%% must be assigned a symbolical size in tokens.
%%
%% The rate is measured and limited over short intervals, by default the
%% interval is set to one second.
%%
%% There is a total amount of tokens allowed to be sent or received by
%% the flow during each interval. As the the number of tokens approaches
%% that limit the probability of a message being delayed increases.
%%
%% When the amount of tokens has exceeded the limit all messages are delayed
%% until the start of the next interval.
%%
%% When the number of tokens needed for a message exceeds the number of tokens
%% allowed per interval the receiver or sender must accumulate tokens over
%% multiple intervals.

%% exported functions
-export([new/3, join/1, wait/2, take/2]).

%% private functions
-export([reset/1]).


%% @doc Create a new rate limited flow.
%% @end
-spec new(atom(), pos_integer() | infinity, non_neg_integer()) -> ok.
new(Name, Limit, Interval) ->
    ets:new(Name, [public, named_table, set]),
    {ok, TRef} = timer:apply_interval(Interval, ?MODULE, reset, [Name]),
    ets:insert(Name, [
        {version, 0},
        {limit, Limit},
        {burst, 5 * Limit},
        {fair, Limit div 5}, %% Should be limit / size(group)
        {tokens, Limit * 5},
        {timer, TRef}]),
    ok.


%% @private Reset the token counter of a flow.
-spec reset(atom()) -> true.
reset(Name) ->
    %% The version number starts at 0 and restarts when it reaches 16#FFFF.
    %% The version number can be rolling because we only use it as a way to
    %% tell logical intervals apart.
    ets:update_counter(Name, version, {2,1,16#FFFF,0}),
    %% Add Limit number of tokens to the bucket at the start of each interval.
    Limit = ets:lookup_element(Name, limit, 2),
    %% Cap the token counter to Limit multiple a number of intevals to protect
    %% us from huge bursts after idle intervals. The default is to only accumulate
    %% five intervals worth of tokens in the bucket.
    Burst = ets:lookup_element(Name, burst, 2),
    ets:update_counter(Name, tokens, {2,Limit,Burst,Burst}).


%% @doc Add the current process as the member of a flow.
%% The process is removed from the flow when it exists. Exiting is the only
%% way to remove a member of a flow.
%% @end
-spec join(atom()) -> ok.
join(_Name) ->
    random:seed(now()),
    ok.


%% @doc Wait until the start of the next interval.
%% @end
-spec wait(atom(), non_neg_integer()) -> non_neg_integer().
wait(Name, _Version) ->
    %% @todo Don't sleep for an arbitrary amount of time.
    timer:sleep(100),
    %% @todo Warn when NewVersion =:= Version
    ets:lookup_element(Name, version, 2).


%% @doc Aquire a slot to send or receive N tokens.
%% @end
-spec take(non_neg_integer(), atom()) -> ok.
take(N, Name) when is_integer(N), N >= 0, is_atom(Name) ->
    Limit = ets:lookup_element(Name, limit, 2),
    Version = ets:lookup_element(Name, version, 2),
    Before = now(),
    ok = take(N, Name, Limit, Version),
    After = now(),
    _Delay = timer:now_diff(After, Before),
    ok.

take(_N, _Name, infinity, _Version) ->
    ok;
take(N, Name, Limit, Version) when N >= 0 ->
    M = slice(N, Limit),
    case ets:update_counter(Name, tokens, [{2,0},{2,-M}]) of
        %% Empty bucket. Wait until the next interval for more tokens.
        [_, Tokens] when Tokens =< 0 ->
            ets:update_counter(Name, tokens, {2,M}),
            NewVersion = wait(Name, Version),
            take(N, Name, Limit, NewVersion);
        [Previous, Tokens] ->
            %% Use difference between the bottom of the bucket and the previous
            %% token count and the packet size to compute the probability of a
            %% message being delayed.
            %% This gives smaller control protocol messages a higher likelyness of
            %% receiving service, avoiding starvation from larger data protocol
            %% messages consuming the rate of entire intervals when a low rate
            %% is used.
            case random:uniform(Previous) of
                %% Allow message if the random number falls within
                %% the range of tokens left in the bucket after take.
                Rand when Rand =< Tokens ->
                    ok;
                 %% Disallow message if the random number falls within
                 %% the range of the tokens taken from the bucket.
                 Rand when Rand > Tokens ->
                    ets:update_counter(Name, tokens, {2,M}),
                    NewVersion = wait(Name, Version),
                    take(N, Name, Limit, NewVersion)
            end
    end.

%% @private Only take at most Limit tokens during an interval.
%% This ensures that we can send messages that are larger than
%% the Limit/Burst of a flow.
-spec slice(non_neg_integer(), non_neg_integer()) -> non_neg_integer().
slice(Tokens, Limit) when Tokens > Limit ->
    Limit;
slice(Tokens, Limit) when Tokens =< Limit ->
    Tokens.


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").


-define(setup(Test),
    {spawn,
    {setup, local,
        fun() ->
            rlimit:new(test_flow, 512, 1000),
            rlimit:join(test_flow)
        end,
        fun(_) -> ok end,
        ?_test(Test)}}).

rlimit_test_() ->
    {inorder,
        [?setup(reset_once()),
         ?setup(take_small()),
         ?setup(take_large()),
         ?setup(take_larger()),
         ?setup(take_huge())]}.

reset_once() ->
    rlimit:reset(test_flow).

take_small() ->
    ok = rlimit:take(512 div 16, test_flow).

take_large() ->
    ok = rlimit:take(512, test_flow).

take_larger() ->
    ok = rlimit:take(512 * 2, test_flow).

take_huge() ->
    ok = rlimit:take(512 * 6, test_flow).

-endif.
