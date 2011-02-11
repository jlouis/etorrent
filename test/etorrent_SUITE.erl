-module(etorrent_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([suite/0, all/0,
	 init_per_suite/1, end_per_suite/1,
	 init_per_testcase/2, end_per_testcase/2]).

-export([seed_leech/1]).

-define(TESTFILE30M, "test_file_30M.random.torrent").

suite() ->
    [{timetrap, {minutes, 3}}].

%% Setup/Teardown
%% ----------------------------------------------------------------------

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
    test_server:stop_node('seeder'),
    test_server:stop_node('leecher'),
    ok.

init_per_testcase(seed_leech, Config) ->
    SN = proplists:get_value(seed_node, Config),
    LN = proplists:get_value(leech_node, Config),
    Data = proplists:get_value(data_dir, Config),
    Priv = proplists:get_value(priv_dir, Config),
    SeedConfig = seed_configuration(Priv, Data),
    LeechConfig = leech_configuration(Priv, Data),
    SeedTorrent = filename:join([Data, ?TESTFILE30M]),
    LeechTorrent = filename:join([Priv, ?TESTFILE30M]),
    file:make_dir(filename:join([Priv, "nothing"])),
    file:copy(SeedTorrent, LeechTorrent),
    ok = rpc:call(SN, etorrent, start_app, [SeedConfig]),
    ok = rpc:call(LN, etorrent, start_app, [LeechConfig]),
    [{sn, SN}, {ln, LN},
     {leech_torrent, LeechTorrent} | Config];
init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(seed_leech, Config) ->
    ok = rpc:call(proplists:get_value(ln, Config), etorrent, stop_app, []),
    ok = rpc:call(proplists:get_value(sn, Config), etorrent, stop_app, []),
    Priv = proplists:get_value(priv_dir, Config),
    ok = file:delete(filename:join([Priv, ?TESTFILE30M])),
    ok = file:delete(filename:join([Priv, "nothing", ?TESTFILE30M])),
    ok = file:del_dir(filename:join([Priv, "nothing"]));
end_per_testcase(_Case, _Config) ->
    ok.

%% Configuration
%% ----------------------------------------------------------------------
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

seed_configuration(PrivDir, DataDir) ->
    [{port, 1739 },
     {udp_port, 1740 },
     {dht_state, filename:join([PrivDir, "seeder_state.persistent"])},
     {dir, DataDir},
     {download_dir, DataDir},
     {logger_dir, PrivDir},
     {logger_fname, "seed_etorrent.log"},
     {fast_resume_file, filename:join([PrivDir, "seed_fast_resume"])} | common_configuration()].

leech_configuration(PrivDir, DataDir) ->
    [{port, 1769 },
     {udp_port, 1760 },
     {dht_state, filename:join([PrivDir, "leecher_state.persistent"])},
     {dir, filename:join([PrivDir, "nothing"])},
     {download_dir, filename:join([PrivDir, "nothing"])},
     {logger_dir, PrivDir},
     {logger_fname, "leech_etorrent.log"},
     {fast_resume_file, filename:join([PrivDir, "leech_fast_resume"])} | common_configuration()].

%% Tests
%% ----------------------------------------------------------------------
all() ->
    [seed_leech].

seed_leech(Config) ->
    {Ref, Pid} = {make_ref(), self()},
    ok = rpc:call(proplists:get_value(ln, Config),
		  etorrent, start,
		  [proplists:get_value(leech_torrent, Config), {Ref, Pid}]),
    receive
	{Ref, done} -> ok
    after
	120*1000 -> exit(timeout_error)
    end.

%% Helpers
%% ----------------------------------------------------------------------
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

