%% @doc LEDBAT calculations
%%
%% == Overview ==
%% The code in this module maintains a LEDBAT calculation based upon
%% delay samples. A sample is the difference between two clocks, A and
%% B which we assume are moving onwards at the same speed, though we
%% do account for skew.
%%
%% The difference between our and their clock (A and B) is our base
%% delay. Any deviation from this difference in the positive direction
%% means we have a queuing delay of that amount. A deviation in the
%% negative direction means that we have to update our base delay to
%% the new value.
%%
%% == Base Delay and Current Delay ==
%% When we take in samples, we store these samples historically. This
%% is done such that small perturbances in the delay will not affect
%% the greater scheme of things. We track two kinds of delays: The
%% base history and the current (queue) history. Every minute, we
%% update and rotate the history tables so we never latch onto a
%% simplified view of the real world.
%% @end
-module(utp_ledbat).

-define(BASE_DELAY_HISTORY_SIZE, 12).
-define(CUR_DELAY_SIZE, 2).

-export([
         mk/1,
         add_sample/2,
         shift/2,
         get_value/1,
         clock_tick/1
        ]).

-record(ledbat, {
          base_history_q :: queue(),
          delay_base :: integer(),
          last_sample :: integer(),
          cur_delay_history_q   :: queue() }).

-opaque t() :: #ledbat{}.

-export_type([
              t/0
             ]).

%% @doc Create a new LEDBAT structure based upon the first sample
%% @end
mk(Sample) ->
    BaseQueue = lists:foldr(fun(_E, Q) -> queue:in(Sample, Q) end,
                            queue:new(),
                            lists:seq(1, ?BASE_DELAY_HISTORY_SIZE)),
    DelayQueue = lists:foldr(fun(_E, Q) -> queue:in(0, Q) end,
                             queue:new(),
                             lists:seq(1, ?CUR_DELAY_SIZE)),
    #ledbat { base_history_q = BaseQueue,
              delay_base     = Sample,
              last_sample    = Sample,
              cur_delay_history_q = DelayQueue}.

%% @doc Shift the base delay by an `Offset' amount.  Note that
%% shifting by a positive value moves the base delay such that the
%% queueing delay gets smaller. This is used in several spots to
%% account for the fact that we just realized our queueing delay is
%% too large. To make it smaller we shift the base delay up, which
%% affects the queueing delay down.
%% @end
shift(#ledbat { base_history_q = BQ } = LEDBAT, Offset) ->
    New_Queue = queue_map(fun(E) ->
                                  utp_util:bit32(E + Offset)
                          end,
                          BQ),
    LEDBAT#ledbat { base_history_q = New_Queue }.

%% @doc Add a new sample to the LEDBAT structure
%% @end
add_sample(none, Sample) ->
    mk(Sample);
add_sample(#ledbat { base_history_q = BQ,
                     delay_base     = DelayBase,
                     cur_delay_history_q   = DQ } = LEDBAT, Sample) ->
    {{value, BaseIncumbent}, BQ2} = queue:out(BQ),
    N_BQ = case compare_less(Sample, BaseIncumbent) of
               true ->
                   queue:in_r(Sample, BQ2);
               false ->
                   BQ
           end,
    N_DelayBase = case compare_less(Sample, DelayBase) of
                      true -> Sample;
                      false -> DelayBase
                  end,
    Delay = utp_util:bit32(Sample - N_DelayBase),
    N_DQ = update_history(Delay, DQ),
    LEDBAT#ledbat { base_history_q = N_BQ,
                    delay_base = Delay,
                    last_sample = Sample,
                    cur_delay_history_q = N_DQ }.

%% @doc Bump the internal structure by rotating the history tables
%% @end
clock_tick(none) ->
    none;
clock_tick(#ledbat{ base_history_q  = BaseQ,
                    last_sample = Sample,
                    delay_base = DelayBase } = LEDBAT) ->
    N_BaseQ = queue:in_r(Sample, queue:drop(rotate(BaseQ))),
    N_DelayBase = minimum_by(fun compare_less/2, queue:to_list(N_BaseQ)),
    LEDBAT#ledbat { base_history_q = N_BaseQ,
                    delay_base = min(N_DelayBase, DelayBase) }.

%% @doc Get out the current estimate.
%% @end
get_value(#ledbat { cur_delay_history_q = DelayQ }) ->
    lists:min(queue:to_list(DelayQ)).

%% ----------------------------------------------------------------------
update_history(Sample, Queue) ->
    {{value, _ThrowAway}, RestOfQueue} = queue:out(Queue),
    queue:in(Sample, RestOfQueue).

minimum_by(_F, []) ->
    error(badarg);
minimum_by(F, [H | T]) ->
    minimum_by(F, T, H).

minimum_by(_Comparator, [], M) ->
    M;
minimum_by(Comparator, [H | T], M) ->
    case Comparator(H, M) of
        true ->
            minimum_by(Comparator, T, H);
        false ->
            minimum_by(Comparator, T, M)
    end.

rotate(Q) ->
    {{value, E}, RQ} = queue:out(Q),
    queue:in(E, RQ).

%% @doc Compare if L < R taking wrapping into account
compare_less(L, R) ->
    %% To see why this is correct, imagine a unit circle
    %% One direction is walking downwards from the L clockwise until
    %%  we hit the R
    %% The other direction is walking upwards, counter-clockwise
    Down = utp_util:bit32(L - R),
    Up   = utp_util:bit32(R - L),

    %% If the walk-up distance is the shortest, L < R, otherwise R < L
    Up < Down.

queue_map(F, Q) ->
    L = queue:to_list(Q),
    queue:from_list(lists:map(F, L)).









