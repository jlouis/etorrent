-module(utp_filter).

-export([start/0, start/1,
         clear/1]).


start() ->
    start([]).

start(ExtraOptions) ->
    Options =
        [{event_order, event_ts},
         {scale, 2},
         {max_actors, 10},
         {detail_level, 90},
         {actors, [client, timer, us, peer]},
         {trace_pattern, {utp, max}},
         {trace_global, true},
         {title, "uTP tracer"} | ExtraOptions],
    et_viewer:start(Options).


clear(P) ->
    ColPid = et_viewer:get_collector_pid(P),
    ok = et_collector:clear_table(ColPid).
