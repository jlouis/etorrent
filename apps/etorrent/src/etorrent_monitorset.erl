-module(etorrent_monitorset).
-export([new/0,
         size/1,
         insert/3,
         update/3,
         delete/2,
         fetch/2,
         is_member/2]).

-type monitorset() :: gb_tree().
-export_type([monitorset/0]).

%% @doc
%% Create an empty set of process monitors.
%% @end
-spec new() -> monitorset().
new() ->
    gb_trees:empty().

%% @doc
%%
%% @end
-spec size(monitorset()) -> pos_integer().
size(Monitorset) ->
    gb_trees:size(Monitorset).

%% @doc
%%
%% @end
-spec insert(pid(), term(), monitorset()) -> monitorset().
insert(Pid, Value, Monitorset) ->
    MRef = monitor(process, Pid),
    gb_trees:insert(Pid, {MRef, Value}, Monitorset).

%% @doc
%%
%% @end
-spec update(pid(), term(), monitorset()) -> monitorset().
update(Pid, Value, Monitorset) ->
    {MRef, _} = gb_trees:get(Pid, Monitorset),
    gb_trees:update(Pid, {MRef, Value}, Monitorset).

%% @doc
%%
%% @end
-spec delete(pid(), monitorset()) -> monitorset().
delete(Pid, Monitorset) ->
    {MRef, _} = gb_trees:get(Pid, Monitorset),
    true = demonitor(MRef, [flush]),
    gb_trees:delete(Pid, Monitorset).

%% @doc
%%
%% @end
-spec is_member(pid(), monitorset()) -> boolean().
is_member(Pid, Monitorset) ->
    gb_trees:is_defined(Pid, Monitorset).

%% @doc
%%
%% @end
-spec fetch(pid(), monitorset()) -> term().
fetch(Pid, Monitorset) ->
    {_, Value} = gb_trees:get(Pid, Monitorset),
    Value.


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(monitors, etorrent_monitorset).

empty_size_test() ->
    Set = ?monitors:new(),
    ?assertEqual(0, ?monitors:size(Set)).

insert_increase_size_test() ->
    Set0 = ?monitors:new(),
    Set1 = ?monitors:insert(noop_proc(), 0, Set0),
    Set2 = ?monitors:insert(noop_proc(), 1, Set1),
    ?assertEqual(1, ?monitors:size(Set1)),
    ?assertEqual(2, ?monitors:size(Set2)).

state_value_test() ->
    Set0 = ?monitors:new(),
    Ref0 = noop_proc(),
    Ref1 = noop_proc(),
    Set1 = ?monitors:insert(Ref0, 0, Set0),
    Set2 = ?monitors:insert(Ref1, 1, Set1),
    ?assertEqual(0, ?monitors:fetch(Ref0, Set1)),
    ?assertEqual(1, ?monitors:fetch(Ref1, Set2)).

delete_value_test() ->
    Set0 = ?monitors:new(),
    Ref0 = noop_proc(),
    Ref1 = noop_proc(),
    Set1 = ?monitors:insert(Ref0, 0, Set0),
    Set2 = ?monitors:insert(Ref1, 1, Set1),
    Set3 = ?monitors:delete(Ref0, Set2),
    ?assertEqual(1, ?monitors:fetch(Ref1, Set3)).

is_member_test() ->
    Set0 = ?monitors:new(),
    Ref0 = noop_proc(),
    Ref1 = noop_proc(),
    Set1 = ?monitors:insert(Ref0, 0, Set0),
    Set2 = ?monitors:insert(Ref1, 1, Set1),
    ?assert(?monitors:is_member(Ref0, Set2)),
    ?assert(?monitors:is_member(Ref1, Set2)),
    Set3 = ?monitors:delete(Ref1, Set2),
    ?assert(?monitors:is_member(Ref0, Set3)),
    ?assert(not ?monitors:is_member(Ref1, Set3)).

monitor_one_test() ->
    Set0 = ?monitors:new(),
    Pid  = noop_proc(),
    Set1 = ?monitors:insert(Pid, 0, Set0),
    Pid ! shutdown,
    ?assert(was_monitored(Pid)).

demonitor_one_test() ->
    Set0 = ?monitors:new(),
    Pid  = noop_proc(),
    Set1 = ?monitors:insert(Pid, 0, Set0),
    Set2 = ?monitors:delete(Pid, Set1),
    Pid ! shutdown,
    ?assert(not was_monitored(Pid)).
    

noop_proc() ->
    spawn_link(fun() -> receive shutdown -> ok end end).

was_monitored(Pid) ->
    receive
        {'DOWN', _, _, Pid, _} -> true
        after 100 -> false
    end.
    

-endif.
