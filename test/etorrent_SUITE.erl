-module(etorrent_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([suite/0, all/0,
	 init_per_suite/1, end_per_suite/1,
	 init_per_testcase/2, end_per_testcase/2]).

-export([member/1]).

suite() ->
    [{timetrap, {minutes, 1}}].

init_per_suite(Config) ->
    %% We should really use priv_dir here, but as we are for-once creating
    %% files we will later rely on for fetching, this is ok I think.
    Directory = proplists:get_value(data_dir, Config),
    io:format("Data directory: ~s~n", [Directory]),
    TestFn = "test_file_30M.random",
    Fn = filename:join([Directory, TestFn]),
    ensure_random_file(Fn),
    file:set_cwd(Directory),
    ensure_torrent_file(TestFn),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(_Case, _Config) ->
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

ensure_torrent_file(Fn) ->
    case filelib:is_regular(Fn ++ ".torrent") of
	true ->
	    ok;
	false ->
	    etorrent_mktorrent:create(
	      Fn, "http://localhost:6969", Fn ++ ".torrent")
    end.

ensure_random_file(Fn) ->
    case filelib:is_regular(Fn) of
	true ->
	    ok;
	false ->
	    create_torrent_file(Fn)
    end.

create_torrent_file(FName) ->
    random:seed({137, 314159265, 1337}),
    Bin = create_binary(30*1024*1024, <<>>),
    file:write_file(FName, Bin).

create_binary(0, Bin) -> Bin;
create_binary(N, Bin) ->
    Byte = random:uniform(256) - 1,
    create_binary(N-1, <<Bin/binary, Byte:8/integer>>).

