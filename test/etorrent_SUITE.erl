-module(etorrent_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([suite/0, all/0,
	 init_per_suite/1, end_per_suite/1,
	 init_per_testcase/2, end_per_testcase/2]).

-export([member/1, seed_leech/1]).

suite() ->
    [{timetrap, {minutes, 3}}].

start_opentracker(Dir) ->
    ToSpawn = "run_opentracker.sh -i 127.0.0.1 -p 6969",
    Spawn = filename:join([Dir, ToSpawn]),
    Pid = spawn(fun() ->
			Port = open_port(
				 {spawn, Spawn}, [binary, stream, eof]),
			receive
			    close ->
				port_close(Port)
			end
		end),
    Pid.

stop_opentracker(Pid) ->
    Pid ! close.

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
    Pid = start_opentracker(Directory),
    {ok, SeedNode} = test_server:start_node('seeder', slave, []),
    {ok, LeechNode} = test_server:start_node('leecher', slave, []),
    [{tracker_port, Pid},
     {leech_node, LeechNode},
     {seed_node, SeedNode} | Config].

end_per_suite(Config) ->
    Pid = proplists:get_value(tracker_port, Config),
    stop_opentracker(Pid),
    ok.

init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(_Case, _Config) ->
    ok.

common_configuration() ->
  [
   {dirwatch_interval, 20 },
   {dht, false },
   {dht_port, 6882 },
   {max_peers, 200},
   {max_upload_rate, 175},
   {max_upload_slots, auto},
   {fs_watermark_high, 128},
   {fs_watermark_low, 100},
   {min_uploads, 2},
   {preallocation_strategy, sparse },
   {webui, false },
   {webui_logger_dir, "log/webui"},
   {webui_bind_address, {127,0,0,1}},
   {webui_port, 8080},
   {profiling, false}
  ].

seed_configuration(Config) ->
    PrivDir = proplists:get_value(priv_dir, Config),
    DataDir = proplists:get_value(data_dir, Config),
    [{port, 1739 },
     {udp_port, 1740 },
     {dht_state, filename:join([PrivDir, "seeder_state.persistent"])},
     {dir, DataDir},
     {download_dir, DataDir},
     {logger_dir, PrivDir},
     {logger_fname, "seed_etorrent.log"},
     {fast_resume_file, filename:join([PrivDir, "seed_fast_resume"])} | common_configuration()].

leech_configuration(Config) ->
    PrivDir = proplists:get_value(priv_dir, Config),
    DataDir = proplists:get_value(data_dir, Config),
    [{port, 1769 },
     {udp_port, 1760 },
     {dht_state, filename:join([PrivDir, "leecher_state.persistent"])},
     {dir, filename:join([PrivDir, "nothing"])},
     {download_dir, filename:join([PrivDir, "nothing"])},
     {logger_dir, PrivDir},
     {logger_fname, "leech_etorrent.log"},
     {fast_resume_file, filename:join([PrivDir, "leech_fast_resume"])} | common_configuration()].

cleanfiles_leecher(Config) ->
    Priv = proplists:get_value(priv_dir, Config),
    file:delete(filename:join([Priv, "test_file_30M.random.torrent"])),
    ok.

seed_leech(Config) ->
    SN = proplists:get_value(seed_node, Config),
    LN = proplists:get_value(leech_node, Config),
    Data = proplists:get_value(data_dir, Config),
    Priv = proplists:get_value(priv_dir, Config),
    Priv =/= Data,
    SeedConfig = seed_configuration(Config),
    LeechConfig = leech_configuration(Config),
    SeedTorrent = filename:join([Data, "test_file_30M.random.torrent"]),
    LeechTorrent = filename:join([Priv, "test_file_30M.random.torrent"]),
    file:make_dir(filename:join([Priv, "nothing"])),
    file:copy(SeedTorrent, LeechTorrent),
    ok = rpc:call(SN, etorrent, start_app, [SeedConfig]),
    ok = rpc:call(LN, etorrent, start_app, [LeechConfig]),
    {Ref, Pid} = {make_ref(), self()},
    ok = rpc:call(LN, etorrent, start, [LeechTorrent, {Ref, Pid}]),
    receive
	{Ref, done} -> ok
    after
	120*1000 -> exit(timeout_error)
    end,
    ok = rpc:call(LN, etorrent, stop_app, []),
    ok = rpc:call(SN, etorrent, stop_app, []),
    cleanfiles_leecher(Config),
    ok.

all() ->
    [member, seed_leech].

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
	      Fn, "http://localhost:6969/announce", Fn ++ ".torrent")
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

