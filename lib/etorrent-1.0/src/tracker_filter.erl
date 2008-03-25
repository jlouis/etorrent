-module(tracker_filter).
-export([start/0]).

-include_lib("et/include/et.hrl").

start() ->
    Options =
	[{event_order, event_ts},
	  {scale, 3},
	  {max_actors, infinity},
	  {trace_pattern, {et, max}},
	  {trace_global, true},
	  {dict_insert, {filter, ?MODULE}, fun filter/1},
	  {active_filter, ?MODULE},
	  {title, "Etorrent Tracker Tracker"}],
    et_viewer:start(Options).

filter(E) when record(E, event) ->
    true.


