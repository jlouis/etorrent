-module(utp_ledbat).

-define(BASE_DELAY_HISTORY_SIZE, 13).
-define(CUR_DELAY_SIZE, 3).
-define(INITIAL_RTT_VARIANCE, 800). % ms

-export([
         mk/1,
         add_sample/2,
         shift/2,
         get_value/1,
         clock_tick/1
        ]).

-record(ledbat, {
          round_trip_time :: integer(),
          round_trip_time_variance :: integer(),
          base_history_q :: queue(),
          delay_base :: integer(),
          last_sample :: integer(),
          cur_delay_history_q   :: queue() }).

-opaque t() :: #ledbat{}.

-export_type([
              t/0
             ]).

mk(Sample) ->
    BaseQueue = lists:foldr(fun(_E, Q) -> queue:in(Sample, Q) end,
                            queue:new(),
                            lists:seq(1, ?BASE_DELAY_HISTORY_SIZE)),
    DelayQueue = lists:foldr(fun(_E, Q) -> queue:in(0, Q) end,
                             queue:new(),
                             lists:seq(1, ?CUR_DELAY_SIZE)),
    #ledbat { base_history_q = BaseQueue,
              round_trip_time_variance = ?INITIAL_RTT_VARIANCE,
              delay_base     = Sample,
              last_sample    = Sample,
              cur_delay_history_q = DelayQueue}.

shift(#ledbat { base_history_q = BQ } = LEDBAT, Offset) ->
    New_Queue = queue_map(fun(E) ->
                                  utp_util:bit32(E + Offset)
                          end,
                          BQ),
    LEDBAT#ledbat { base_history_q = New_Queue }.

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

clock_tick(#ledbat{ base_history_q  = BaseQ,
                    last_sample = Sample,
                    delay_base = DelayBase } = LEDBAT) ->
    N_BaseQ = queue:in_r(Sample, queue:drop(rotate(BaseQ))),
    N_DelayBase = minimum_by(fun compare_less/2, queue:to_list(N_BaseQ)),
    LEDBAT#ledbat { base_history_q = N_BaseQ,
                    delay_base = min(N_DelayBase, DelayBase) }.


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


