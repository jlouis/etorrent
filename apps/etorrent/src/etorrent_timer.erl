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
%% The interface provided to the test code is effectively only
%% the step/1 function that fires the next timer, see Guarantees.
%% This also decreases the timeout of all remaining timers by the
%% interval of the timer that fired to ensure the relative order
%% of existing and new timers.
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
         fire_now/1,
         fire_later/1]).

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
    fired :: boolean(),
    reference :: reference(),
    interval :: pos_integer(),
    process  :: pid(),
    message  :: term()}).

-record(state, {
    mode :: mode(),
    ahead :: boolean(),
    timers :: list()}).


-spec start_link(mode()) -> {ok, pid()}.
start_link(Mode) ->
    gen_server:start_link(?MODULE, Mode, []).


-spec send_after(server(), pos_integer(), pid(), term()) -> reference().
send_after(Server, Time, Dest, Msg) ->
    case Server of
        native -> erlang:send_after(Time, Dest, Msg);
        Server -> gen_server:call(Server, {send_after, Time, Dest, Msg})
    end.


-spec start_timer(server(), pos_integer(), pid(), term()) -> reference().
start_timer(Server, Time, Dest, Msg) ->
    case Server of
        native -> erlang:start_timer(Time, Dest, Msg);
        Server -> gen_server:call(Server, {start_timer, Time, Dest, Msg})
    end.


-spec cancel(server(), reference()) -> pos_integer() | false.
cancel(Server, Timer) ->
    case Server of
        native -> erlang:cancel_timer(Timer);
        Server -> gen_server:call(Server, {cancel, Timer})
    end.


-spec fire_now(server()) -> pos_integer().
fire_now(Server) ->
    case Server of
        native -> error(badarg);
        Server -> gen_server:call(Server, fire_now)
    end.


-spec fire_later(server()) -> pos_integer().
fire_later(Server) ->
    case Server of
        native -> error(badarg);
        Server -> gen_server:call(Server, fire_later)
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
            Dest ! Msg,
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
        %% Timer has been fired with fire_later, it's a bit unclear what we
        %% should do at this point but the most practical thing to do would
        %% be to deliver the message before this call returns to create a case
        %%  where the message is delivered but not received when a timer
        %% is cancelled.
        #timer{fired=true} ->
            deliver(Timer),
            NewTimers = delete_timer(Timer, Timers),
            NewState = State#state{timers=NewTimers},
            {reply, false, NewState};
        %% Timer has not been fired. We should not try to infer that any time
        %% has passed since the timer was created since this could be called
        %% immidiately after a timer is created. Never deliver a message in this
        %% case so that tests can rely on clean cancellations of timers.
        #timer{fired=false} ->
            #timer{interval=Interval} = Timer,
            NewTimers = delete_timer(Timer, Timers),
            NewState = State#state{timers=NewTimers},
            {reply, Interval, NewState}
    end;

handle_call(fire_now, _, State) ->
    %% TODO - catch up with timers that has been fired using fire_later
    #state{timers=Timers} = State,
    Min = min_interval(Timers),
    %% Fire and delete all timers that share the lowest interval
    Now = with_interval(Min, Timers),
    TmpTimers = lists:foldl(fun(Timer, Acc) ->
        deliver(Timer),
        delete_timer(Timer, Acc)
    end, Timers, Now),
    %% Subtract the lowest interval from all remaining timers.
    NewTimers = subtract(Min, TmpTimers),
    NewState = State#state{timers=NewTimers},
    {reply, length(Now), NewState};

handle_call(fire_later, _, _) ->
    %% TODO - implement me
    error(badarg).

handle_cast(_, _) -> error(badarg).
handle_info(_, _) -> error(badarg).
terminate(_, _) -> error(badarg).
code_change(_, _, _) -> error(badarg).


    

sort_timers(Timers) ->
    lists:keysort(#timer.interval, Timers).

find_timer(Ref, Timers) ->
    lists:keyfind(Ref, #timer.reference, Timers).

delete_timer(Timer, Timers) ->
    #timer{reference=Ref} = Timer,
    lists:keydelete(Ref, #timer.reference, Timers).

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
