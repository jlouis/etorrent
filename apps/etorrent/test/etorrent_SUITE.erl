-module(etorrent_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([suite/0, all/0,
	 init_per_suite/1, end_per_suite/1,
	 init_per_testcase/2, end_per_testcase/2]).

-export([member/1]).

suite() ->
    [{timetrap, {minutes, 1}}].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(_Case, Config) ->
    ok.

all() ->
    [member].

member(Config) when is_list(Config) ->
    ?line {'EXIT',{badarg,_}} = (catch lists:member(45, {a,b,c})),
    ?line {'EXIT',{badarg,_}} = (catch lists:member(45, [0|non_list_tail])),
    ?line false = lists:member(4233, []),
    ?line member_test(1),
    ?line member_test(100),
    ?line member_test(256),
    ?line member_test(1000),
    ?line member_test(1998),
    ?line member_test(1999),
    ?line member_test(2000),
    ?line member_test(2001),
    ?line member_test(3998),
    ?line member_test(3999),
    ?line member_test(4000),
    ?line member_test(4001),
    ?line member_test(100008),
    ok.
member_test(Num) ->
    List0 = ['The Element'|lists:duplicate(Num, 'Elem')],
    true = lists:member('The Element', List0),
    true = lists:member('Elem', List0),
    false = lists:member(arne_anka, List0),
    false = lists:member({a,b,c}, List0),
    List = lists:reverse(List0),
    true = lists:member('The Element', List),
    true = lists:member('Elem', List),
    false = lists:member(arne_anka, List),
    false = lists:member({a,b,c}, List).
