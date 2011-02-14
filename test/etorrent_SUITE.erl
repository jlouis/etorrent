-module(etorrent_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([suite/0, all/0, groups/0,
	 init_per_group/2, end_per_group/2,
	 init_per_suite/1, end_per_suite/1,
	 init_per_testcase/2, end_per_testcase/2]).

-export([seed_leech/0, seed_leech/1,
	 seed_transmission/0, seed_transmission/1,
	 leech_transmission/0, leech_transmission/1]).

-define(TESTFILE30M, "test_file_30M.random").

suite() ->
    [{timetrap, {minutes, 3}}].

%% Setup/Teardown
%% ----------------------------------------------------------------------
init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_suite(Config) ->
    %% We should really use priv_dir here, but as we are for-once creating
    %% files we will later rely on for fetching, this is ok I think.
    Directory = ?config(data_dir, Config),
    io:format("Data directory: ~s~n", [Directory]),
    TestFn = ?TESTFILE30M,
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
    Pid = ?config(tracker_port, Config),
    LN = ?config(leech_node, Config),
    SN = ?config(seed_node, Config),
    stop_opentracker(Pid),
    test_server:stop_node(SN),
    test_server:stop_node(LN),
    ok.

init_per_testcase(leech_transmission, Config) ->
    Data = ?config(data_dir, Config),
    LN = ?config(leech_node, Config),
    Priv = ?config(priv_dir, Config),
    CommonConf = ct:get_config(common_conf),
    LeechConfig = leech_configuration(CommonConf, Priv, "nothing-et"),
    SeedTorrent = filename:join([Data, ?TESTFILE30M ++ ".torrent"]),
    TransmissionSeedTorrent =
	filename:join([Priv, "nothing", ?TESTFILE30M ++ ".torrent"]),
    LeechTorrent = filename:join([Priv, ?TESTFILE30M ++ ".torrent"]),
    SeedFile = filename:join([Data, ?TESTFILE30M]),
    LeechFile = filename:join([Priv, "nothing-et", ?TESTFILE30M]),
    TransmissionSeedFile = filename:join([Priv, "nothing", ?TESTFILE30M]),
    file:make_dir(filename:join([Priv, "nothing"])),
    file:make_dir(filename:join([Priv, "nothing-et"])),
    {ok, _} = file:copy(SeedTorrent, LeechTorrent),
    {ok, _} = file:copy(SeedTorrent, TransmissionSeedTorrent),
    {ok, _} = file:copy(SeedFile, TransmissionSeedFile),
    DownloadDir = filename:join([Priv, "nothing"]),
    {ok, _} = file:copy(filename:join([Data, "transmission", "settings.json"]),
			filename:join([DownloadDir, "settings.json"])),
    {Ref, Pid} = start_transmission(Data,
				    DownloadDir,
				    LeechTorrent),
    ok = ct:sleep({seconds, 8}), %% Wait for transmission to start up
    ok = rpc:call(LN, etorrent, start_app, [LeechConfig]),
    [{ln, LN},
     {transmission_port, {Ref, Pid}},
     {seed_torrent, SeedTorrent},
     {leech_torrent, LeechTorrent},
     {seed_file, SeedFile},
     {leech_file, LeechFile} | Config];
init_per_testcase(seed_transmission, Config) ->
    Data = ?config(data_dir, Config),
    SN = ?config(seed_node, Config),

    Priv = ?config(priv_dir, Config),
    CommonConf = ct:get_config(common_conf),
    SeedConfig = seed_configuration(CommonConf, Priv, Data),
    SeedTorrent = filename:join([Data, ?TESTFILE30M ++ ".torrent"]),
    LeechTorrent = filename:join([Priv, ?TESTFILE30M ++ ".torrent"]),
    SeedFile = filename:join([Data, ?TESTFILE30M]),
    LeechFile = filename:join([Priv, "nothing", ?TESTFILE30M]),
    file:make_dir(filename:join([Priv, "nothing"])),
    {ok, _} = file:copy(SeedTorrent, LeechTorrent),
    DownloadDir = filename:join([Priv, "nothing"]),
    {ok, _} = file:copy(filename:join([Data, "transmission", "settings.json"]),
			filename:join([DownloadDir, "settings.json"])),
    {Ref, Pid} = start_transmission(Data,
				    DownloadDir,
				    LeechTorrent),
    ok = ct:sleep({seconds, 8}), %% Wait for transmission to start up
    ok = rpc:call(SN, etorrent, start_app, [SeedConfig]),
    [{sn, SN},
     {transmission_port, {Ref, Pid}},
     {seed_torrent, SeedTorrent},
     {leech_torrent, LeechTorrent},
     {seed_file, SeedFile},
     {leech_file, LeechFile} | Config];
init_per_testcase(seed_leech, Config) ->
    SN = ?config(seed_node, Config),
    LN = ?config(leech_node, Config),
    Data = ?config(data_dir, Config),
    Priv = ?config(priv_dir, Config),
    CommonConf = ct:get_config(common_conf),
    SeedConfig = seed_configuration(CommonConf, Priv, Data),
    LeechConfig = leech_configuration(CommonConf, Priv),
    SeedTorrent = filename:join([Data, ?TESTFILE30M ++ ".torrent"]),
    LeechTorrent = filename:join([Priv, ?TESTFILE30M ++ ".torrent"]),
    SeedFile = filename:join([Data, ?TESTFILE30M]),
    LeechFile = filename:join([Priv, "nothing", ?TESTFILE30M]),
    file:make_dir(filename:join([Priv, "nothing"])),
    file:copy(SeedTorrent, LeechTorrent),
    ok = rpc:call(SN, etorrent, start_app, [SeedConfig]),
    ok = rpc:call(LN, etorrent, start_app, [LeechConfig]),
    [{sn, SN}, {ln, LN},
     {seed_torrent, SeedTorrent},
     {leech_torrent, LeechTorrent},
     {seed_file, SeedFile},
     {leech_file, LeechFile} | Config];
init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(leech_transmission, Config) ->
    ok = rpc:call(?config(ln, Config), etorrent, stop_app, []),
    Priv = ?config(priv_dir, Config),
    ?line ok = file:delete(filename:join([Priv, "nothing-et", ?TESTFILE30M])),
    ?line ok = file:delete(filename:join([Priv, ?TESTFILE30M ++ ".torrent"])),
    ?line ok = file:delete(filename:join([Priv, "nothing", ?TESTFILE30M]));
end_per_testcase(seed_transmission, Config) ->
    ok = rpc:call(?config(sn, Config), etorrent, stop_app, []),
    Priv = ?config(priv_dir, Config),
    ?line ok = file:delete(filename:join([Priv, ?TESTFILE30M ++ ".torrent"])),
    ?line ok = file:delete(filename:join([Priv, "nothing", ?TESTFILE30M]));
end_per_testcase(seed_leech, Config) ->
    ok = rpc:call(?config(ln, Config), etorrent, stop_app, []),
    ok = rpc:call(?config(sn, Config), etorrent, stop_app, []),
    Priv = ?config(priv_dir, Config),
    ?line ok = file:delete(filename:join([Priv, ?TESTFILE30M ++ ".torrent"])),
    ?line ok = file:delete(filename:join([Priv, "nothing", ?TESTFILE30M]));
end_per_testcase(_Case, _Config) ->
    ok.

%% Configuration
%% ----------------------------------------------------------------------
seed_configuration(CConf, PrivDir, DataDir) ->
    [{port, 1739 },
     {udp_port, 1740 },
     {dht_state, filename:join([PrivDir, "seeder_state.persistent"])},
     {dir, DataDir},
     {download_dir, DataDir},
     {logger_dir, PrivDir},
     {logger_fname, "seed_etorrent.log"},
     {fast_resume_file, filename:join([PrivDir, "seed_fast_resume"])} | CConf].

leech_configuration(CConf, PrivDir) ->
    leech_configuration(CConf, PrivDir, "nothing").

leech_configuration(CConf, PrivDir, DownloadSuffix) ->
    [{port, 1769 },
     {udp_port, 1760 },
     {dht_state, filename:join([PrivDir, "leecher_state.persistent"])},
     {dir, filename:join([PrivDir, DownloadSuffix])},
     {download_dir, filename:join([PrivDir, DownloadSuffix])},
     {logger_dir, PrivDir},
     {logger_fname, "leech_etorrent.log"},
     {fast_resume_file, filename:join([PrivDir, "leech_fast_resume"])} | CConf].

%% Tests
%% ----------------------------------------------------------------------
groups() ->
    [{main_group, [shuffle], [seed_transmission, seed_leech, leech_transmission]}].

all() ->
    [{group, main_group}].

seed_transmission() ->
    [{require, common_conf, etorrent_common_config}].

seed_transmission(Config) ->
    {Ref, Pid} = ?config(transmission_port, Config),
    receive
	{Ref, done} -> ok = stop_transmission(Pid)
    after
	120*1000 -> exit(timeout_error)
    end,
    sha1_file(?config(leech_file, Config)) =:= sha1_file(?config(seed_file, Config)).

leech_transmission() ->
    [{require, common_conf, etorrent_common_config}].

leech_transmission(Config) ->
    {Ref, Pid} = {make_ref(), self()},
    ok = rpc:call(?config(ln, Config),
		  etorrent, start,
		  [?config(leech_torrent, Config), {Ref, Pid}]),
    receive
	{Ref, done} -> ok
    after
	120*1000 -> exit(timeout_error)
    end,
    sha1_file(?config(leech_file, Config)) =:= sha1_file(?config(seed_file, Config)).

seed_leech() ->
    [{require, common_conf, etorrent_common_config}].

seed_leech(Config) ->
    {Ref, Pid} = {make_ref(), self()},
    ok = rpc:call(?config(ln, Config),
		  etorrent, start,
		  [?config(leech_torrent, Config), {Ref, Pid}]),
    receive
	{Ref, done} -> ok
    after
	120*1000 -> exit(timeout_error)
    end,
    sha1_file(?config(leech_file, Config)) =:= sha1_file(?config(seed_file, Config)).

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

quote(Str) ->
    lists:concat(["'", Str, "'"]).

start_transmission(DataDir, DownDir, Torrent) ->
    ToSpawn = ["run_transmission-cli.sh ", quote(Torrent),
	       " -w ", quote(DownDir),
	       " -g ", quote(DownDir),
	       " -p 1780"],
    Spawn = filename:join([DataDir, lists:concat(ToSpawn)]),
    error_logger:info_report([{spawn, Spawn}]),
    Ref = make_ref(),
    Self = self(),
    Pid = spawn_link(fun() ->
			Port = open_port(
				 {spawn, Spawn},
				 [stream, binary, eof]),
			transmission_loop(Port, Ref, Self, <<>>)
		     end),
    {Ref, Pid}.

stop_transmission(Pid) when is_pid(Pid) ->
    Pid ! close,
    ok.

transmission_complete_criterion() ->
    "Seeding, uploading to".

transmission_loop(Port, Ref, ReturnPid, OldBin) ->
    case binary:split(OldBin, [<<"\r">>, <<"\n">>]) of
	[OnePart] ->
	    receive
		{Port, {data, Data}} ->
		    transmission_loop(Port, Ref, ReturnPid, <<OnePart/binary,
							      Data/binary>>);
		close ->
		    port_close(Port);
		M ->
		    error_logger:error_report([received_unknown_msg, M]),
		    transmission_loop(Port, Ref, ReturnPid, OnePart)
	    end;
	[L, Rest] ->
	    case string:str(binary_to_list(L), transmission_complete_criterion()) of
		0 -> ok;
		N when is_integer(N) ->
		    ReturnPid ! {Ref, done}
	    end,
	    transmission_loop(Port, Ref, ReturnPid, Rest)
    end.

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

sha1_file(F) ->
    Ctx = crypto:sha_init(),
    {ok, FD} = file:open(F, [read,binary,raw]),
    FinCtx = sha1_round(FD, file:read(FD, 1024*1024), Ctx),
    crypto:sha_final(FinCtx).

sha1_round(_FD, eof, Ctx) ->
    Ctx;
sha1_round(FD, {ok, Data}, Ctx) ->
    sha1_round(FD, file:read(FD, 1024*1024), crypto:sha_update(Ctx, Data)).

