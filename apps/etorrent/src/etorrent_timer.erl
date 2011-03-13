-module(etorrent_timer).
-behaviour(gen_server).
%% #Purpose
%% This module implements an interface to interact with the
%% erlang timer interface with the notion of a timer server
%% added. Under normal program execution the timer service
%% is provided by the erlang runtime system and works as expected.
%%
%% During unit test execution the timer service can be provided
%% by a process that is under the control of the test code.
%%
%% This ensures that the test code can rely on a guarantee that
%% a timer has, or has not, fired when an assertion is made.
%% Effectively this means that tests can execute as fast as the
%% code under test can run while being more reliable.
%%
%% #Interface
%% The interface to the timer service should resemble that of
%% the built in interface with an added parameter for specifying
%% the timer service. Processes that rely on timers must provide
%% a way to let the parent process inject the timer service.
%%
%% The interface provided to the test code is the step/1 and fire/1
%% functions. The step/1 function jumps ahead in time to the next
%% timer event but does not fire it. The fire/1 function jumps ahead
%% in time to the next timer event and fires all timers with an interval
%% of 0 milliseconds.
%% 
%% #Guarantees
%% The erlang timer service does not guarantee that multiple timers
%% that are created consequently with the same time is delivered
%% in the order they are created. The easiest way to avoid a situation
%% where a process relies on this behaviour is to detect such behaviour
%% and fire those timers at same time in random order. This is not
%% applicable if the setting is 'instant'.

%% api functions
-export([start_link/1,
         send_after/4,
         start_timer/4,
         cancel/2,
         step/1,
         fire/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-type server() :: native | pid().
-type mode() :: instant | queue.

-record(timer, {
    type :: message | timeout,
    reference :: reference(),
    interval  :: pos_integer(),
    process   :: pid(),
    message   :: term()}).

-record(state, {
    mode :: mode(),
    timers :: list()}).


-spec start_link(mode()) -> {ok, pid()}.
start_link(Mode) ->
    gen_server:start_link(?MODULE, Mode, []).


-spec send_after(server(), pos_integer(), pid(), term()) -> reference().
send_after(Server, Time, Dest, Msg) ->
    case Server of
        native -> erlang:send_after(Time, Dest, Msg);
        Server -> gen_server:call(Server, {message, Time, Dest, Msg})
    end.


-spec start_timer(server(), pos_integer(), pid(), term()) -> reference().
start_timer(Server, Time, Dest, Msg) ->
    case Server of
        native -> erlang:start_timer(Time, Dest, Msg);
        Server -> gen_server:call(Server, {timeout, Time, Dest, Msg})
    end.


-spec cancel(server(), reference()) -> pos_integer() | false.
cancel(Server, Timer) ->
    case Server of
        native -> erlang:cancel_timer(Timer);
        Server -> gen_server:call(Server, {cancel, Timer})
    end.


%% Return the number of milliseconds that passed
-spec step(server()) -> pos_integer().
step(Server) ->
    case Server of
        native -> error(badarg);
        Server -> gen_server:call(Server, step)
    end.


%% Return the number of timers that fired
-spec fire(server()) -> pos_integer().
fire(Server) ->
    %% Always step before firing timers, bad things will
    %% not happen if fire is called immidiately after step.
    step(Server),
    case Server of
        native -> error(badarg);
        Server -> gen_server:call(Server, fire)
    end.


init(Mode) ->
    InitState = #state{
        mode=Mode,
        timers=[]},
    {ok, InitState}.

handle_call({Type, Time, Dest, Data}, _, State) ->
    #state{mode=Mode, timers=Timers} = State,
    Ref = make_ref(),
    Msg = case Type of
        message -> Data;
        timeout -> {timeout, Ref, Data}
    end,
    Timer = #timer{
        type=Type,
        reference=Ref,
        interval=Time,
        process=Dest,
        message=Msg},
    case Mode of
        instant ->
            deliver(Timer),
            {reply, Ref, State};
        queue ->
            NewTimers = sort_timers([Timer|Timers]),
            NewState = State#state{timers=NewTimers},
            {reply, Ref, NewState}
    end;

handle_call({cancel, Ref}, _, State) ->
    #state{timers=Timers} = State,
    Timer = find_timer(Ref, Timers),
    case Timer of
        %% Timer has already fired and message has been delivered
        false ->
            {reply, false, State};
        %% Deliver the message before this call returns to let us step
        %% ahead in time and create a case where the timer has fired and
        %% the message is in the inbox when the client cancels a timer.
        #timer{interval=0} ->
            deliver(Timer),
            NewTimers = delete_timer(Timer, Timers),
            NewState = State#state{timers=NewTimers},
            {reply, false, NewState};
        %% Timer has not yet fired, just delete the timer and
        %% return the amount of milliseconds left on the timer.
        _ ->
            #timer{interval=Interval} = Timer,
            NewTimers = delete_timer(Timer, Timers),
            NewState = State#state{timers=NewTimers},
            {reply, Interval, NewState}
    end;

handle_call(step, _, State) ->
    #state{timers=Timers} = State,
    case Timers of
        [] ->
            {reply, 0, State};
        _ ->
            Min = min_interval(Timers),
            NewTimers = subtract(Min, Timers),
            NewState = State#state{timers=NewTimers},
            {reply, Min, NewState}
    end;

handle_call(fire, _, State) ->
    #state{timers=Timers} = State,
    FiredTimers = with_interval(0, Timers),
    [deliver(Timer) || Timer <- FiredTimers],
    NewTimers = delete_timers(FiredTimers, Timers),
    NewState = State#state{timers=NewTimers},
    NumFired = length(FiredTimers),
    {reply, NumFired, NewState}.
    

handle_cast(_, _) ->
    error(badarg).


handle_info(_, _) ->
    error(badarg).


terminate(_, State) ->
    {ok, State}.


code_change(_, _, _) ->
    error(badarg).


    

sort_timers(Timers) ->
    lists:keysort(#timer.interval, Timers).

find_timer(Ref, Timers) ->
    lists:keyfind(Ref, #timer.reference, Timers).

delete_timer(Timer, Timers) ->
    #timer{reference=Ref} = Timer,
    lists:keydelete(Ref, #timer.reference, Timers).

delete_timers(List, Timers) ->
    lists:foldl(fun(Timer, Acc) ->
        delete_timer(Timer, Acc)
    end, Timers, List).

min_interval(Timers) ->
    %% Assume that timers are sorted by interval.
    case Timers of
        [] ->
            error(badarg);
        [H|_] ->
            #timer{interval=Interval} = H,
            Interval
    end.

with_interval(Interval, Timers) ->
    [E || #timer{interval=I}=E <- Timers, I == Interval].

deliver(Timer) ->    
    #timer{process=Dest, message=Msg} = Timer,
    Dest ! Msg,
    ok.

subtract(Time, Timers) ->
    [E#timer{interval=(I - Time)} || #timer{interval=I}=E <- Timers].

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(timer, etorrent_timer).

assertMessage(Msg) ->
    receive
        Msg ->
            ?assert(true);
        Other ->
            ?assertEqual(Msg, Other)
        after 0 ->
            ?assertEqual(Msg, make_ref())
    end.

assertNoMessage() ->
    Ref = {no_message, make_ref()},
    self() ! Ref,
    receive
        Ref ->
            ?assert(true);
        Other ->
            ?assertEqual(Ref, Other)
    end.


instant_send_test() ->
    {ok, Pid} = ?timer:start_link(instant),
    Msg = make_ref(),
    Ref = ?timer:send_after(Pid, 1000, self(), Msg),
    assertMessage(Msg).


instant_timeout_test() ->
    {ok, Pid} = ?timer:start_link(instant),
    Msg = make_ref(),
    Ref = ?timer:start_timer(Pid, 1000, self(), Msg),
    assertMessage({timeout, Ref, Msg}).

step_and_fire_test() ->
    {ok, Pid} = ?timer:start_link(queue),
    ?timer:send_after(Pid, 1000, self(), a),
    Ref = ?timer:start_timer(Pid, 3000, self(), b),
    ?timer:send_after(Pid, 6000, self(), c),

    ?assertEqual(1000, ?timer:step(Pid)),
    ?assertEqual(0, ?timer:step(Pid)),
    ?assertEqual(1, ?timer:fire(Pid)),
    assertMessage(a),

    ?assertEqual(2000, ?timer:step(Pid)),
    ?assertEqual(0, ?timer:step(Pid)),
    ?assertEqual(1, ?timer:fire(Pid)),
    assertMessage({timeout, Ref, b}),

    ?assertEqual(3000, ?timer:step(Pid)),
    ?assertEqual(0, ?timer:step(Pid)),
    ?assertEqual(1, ?timer:fire(Pid)),
    assertMessage(c).

cancel_and_step_test() ->
    {ok, Pid} = ?timer:start_link(queue),
    Msg = make_ref(),
    Ref = ?timer:start_timer(Pid, 6000, self(), Msg),
    ?assertEqual(6000, ?timer:cancel(Pid, Ref)),
    ?assertEqual(0, ?timer:step(Pid)),
    assertNoMessage().

step_and_cancel_test() ->
    {ok, Pid} = ?timer:start_link(queue),
    Ref = ?timer:send_after(Pid, 500, self(), a),
    500 = ?timer:step(Pid),
    ?assertEqual(false, ?timer:cancel(Pid, Ref)),
    assertMessage(a).

duplicate_cancel_test() ->
    {ok, Pid} = ?timer:start_link(queue),
    Ref = ?timer:send_after(Pid, 500, self(), b),
    ?assertEqual(500, ?timer:cancel(Pid, Ref)),
    ?assertEqual(false, ?timer:cancel(Pid, Ref)).

-endif.
