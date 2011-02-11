-module(etorrent_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([suite/0, all/0,
	 init_per_suite/1, end_per_suite/1,
	 init_per_testcase/2, end_per_testcase/2]).

-export([seed_leech/0, seed_leech/1,
	 seed_transmission/0, seed_transmission/1]).

-define(TESTFILE30M, "test_file_30M.random").

suite() ->
    [{timetrap, {minutes, 3}}].

%% Setup/Teardown
%% ----------------------------------------------------------------------

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

init_per_testcase(seed_transmission, Config) ->
    SN = ?config(seed_node, Config),
    Data = ?config(data_dir, Config),
    Priv = ?config(priv_dir, Config),
    CommonConf = ct:get_config(common_conf),
    SeedConfig = seed_configuration(CommonConf, Priv, Data),
    SeedTorrent = filename:join([Data, ?TESTFILE30M ++ ".torrent"]),
    LeechTorrent = filename:join([Priv, ?TESTFILE30M ++ ".torrent"]),
    SeedFile = filename:join([Data, ?TESTFILE30M]),
    LeechFile = filename:join([Priv, "nothing", ?TESTFILE30M]),
    file:make_dir(filename:join([Priv, "nothing"])),
    file:copy(SeedTorrent, LeechTorrent),
    ok = rpc:call(SN, etorrent, start_app, [SeedConfig]),
    [{sn, SN},
     {seed_torrent, SeedTorrent},
     {leech_torrent, LeechTorrent},
     {seed_file, SeedFile},
     {download_dir, filename:join([Priv, "nothing"])},
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

end_per_testcase(seed_transmission, Config) ->
    ok = rpc:call(?config(sn, Config), etorrent, stop_app, []),
    Priv = ?config(priv_dir, Config),
    ?line ok = file:delete(filename:join([Priv, ?TESTFILE30M ++ ".torrent"])),
    ?line ok = file:delete(filename:join([Priv, "nothing", ?TESTFILE30M])),
    ?line ok = file:del_dir(filename:join([Priv, "nothing"]));
end_per_testcase(seed_leech, Config) ->
    ok = rpc:call(?config(ln, Config), etorrent, stop_app, []),
    ok = rpc:call(?config(sn, Config), etorrent, stop_app, []),
    Priv = ?config(priv_dir, Config),
    ?line ok = file:delete(filename:join([Priv, ?TESTFILE30M ++ ".torrent"])),
    ?line ok = file:delete(filename:join([Priv, "nothing", ?TESTFILE30M])),
    ?line ok = file:del_dir(filename:join([Priv, "nothing"]));
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
    [{port, 1769 },
     {udp_port, 1760 },
     {dht_state, filename:join([PrivDir, "leecher_state.persistent"])},
     {dir, filename:join([PrivDir, "nothing"])},
     {download_dir, filename:join([PrivDir, "nothing"])},
     {logger_dir, PrivDir},
     {logger_fname, "leech_etorrent.log"},
     {fast_resume_file, filename:join([PrivDir, "leech_fast_resume"])} | CConf].

%% Tests
%% ----------------------------------------------------------------------
all() ->
    [seed_transmission].

seed_transmission() ->
    [{require, common_conf, etorrent_common_config}].

seed_transmission(Config) ->
    {Ref, Pid} = start_transmission(
		   ?config(data_dir, Config),
		   ?config(download_dir, Config),
		   ?config(leech_torrent, Config)),
    receive
	{Ref, done} -> ok = stop_transmission(Pid)
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

start_transmission(DataDir, DownDir, Torrent) ->
    ToSpawn = ["run_transmission-cli.sh '" ,Torrent,
	       "' -w '", DownDir,
	       "' -p 1780"],
    Spawn = filename:join([DataDir, lists:concat(ToSpawn)]),
    Ref = make_ref(),
    Self = self(),
    Pid = spawn_link(fun() ->
			Port = open_port(
				 {spawn, Spawn},
				 [stream, binary, eof]),
			transmission_loop(Port, Ref, Self, <<>>)
		     end),
    {Ref, Pid}.

stop_transmission(Pid) ->
    Pid ! close.

transmission_complete_criterion() ->
    "State changed from \"Incomplete\" to \"Complete\"".

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
	    error_logger:info_report([line, L]),
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

