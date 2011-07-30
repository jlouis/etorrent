-module(utp_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([suite/0, all/0, groups/0,
	 init_per_group/2, end_per_group/2,
	 init_per_suite/1, end_per_suite/1,
	 init_per_testcase/2, end_per_testcase/2]).

-export([connect_n_communicate/0, connect_n_communicate/1,
         backwards_communication/0, backwards_communication/1,
         full_duplex_communication/0, full_duplex_communication/1,
         piggyback/0, piggyback/1,
         rwin_test/0, rwin_test/1,
         close_1/0, close_1/1,
         close_2/0, close_2/1,
         close_3/0, close_3/1,
         connect_n_send_big/0, connect_n_send_big/1 ]).

suite() ->
    [{timetrap, {seconds, 45}}].

%% Setup/Teardown
%% ----------------------------------------------------------------------
init_per_group(Group, Config) when Group == main_group;
                                   Group == parallel_main_group;
                                   Group == stress_group ->
    TCProps = ?config(tc_group_properties, Config),
    {_A,_B,C} = ?config(shuffle, TCProps),
    [{force_seq_no, (65536 - (C rem 5)) rem 65536} | Config];
init_per_group(_Group, Config) ->
    Config.

end_per_group(Grp, Config) when Grp == main_group;
                                Grp == parallel_main_group;
                                Grp == stress_group ->
    Status = ?config(tc_group_result, Config),
    case proplists:get_value(failed, Status) of
        [] ->                                   % no failed cases 
            {return_group_result,ok};
        _Failed ->                              % one or more failed
            {return_group_result,failed}
    end;
end_per_group(_Group, _Config) ->
    ok.

init_per_suite(Config) ->
    ConnectNode = start_node(connector,3334),
    ConnecteeNode = start_node(connectee,3333),
    [{connector, ConnectNode},
     {connectee, ConnecteeNode} | Config].

end_per_suite(Config) ->
    test_server:stop_node(?config(connector, Config)),
    test_server:stop_node(?config(connectee, Config)),
    ok.

init_per_testcase(Case, Config) ->
    ct:pal("****** ~p ************", [Case]),
    Config.

end_per_testcase(_Case, _Config) ->
    ok.


%% Tests
%% ----------------------------------------------------------------------

base_test_cases() ->
    [connect_n_communicate,
     backwards_communication,
     full_duplex_communication,
     rwin_test,
     piggyback,
     close_1,
     close_2,
     close_3,
     connect_n_send_big].

groups() ->
    [{main_group, [shuffle, {repeat_until_any_fail, 30}],
      base_test_cases()},
     {parallel_main_group, [shuffle, parallel, {repeat_until_any_fail, 30}],
      base_test_cases()},
     {stress_group, [{repeat_until_any_fail, 50}],
      [piggyback]}].

all() ->
    [{group, main_group}].

two_way(Config, In, Out) ->
    C1 = ?config(connector, Config),
    C2 = ?config(connectee, Config),
    N = self(),
    R = make_ref(),
    spawn(fun() ->
                  timer:sleep(3000),
                  {Reply, TR} = rpc:call(C1, utp_test, Out, [Config]),
                  ct:log("OUT PATH TRACE:~n~p~n", [TR]),
                  N ! {done, Reply, R}
          end),
    {Reply, TR} = rpc:call(C2, utp_test, In, [Config]),
    ct:log("IN_PATH_TRACE:~n~p~n", [TR]),
    case Reply of
        ok -> ignore;
        {error, Reason} -> ct:fail({in, Reason})
    end,
    receive
        {done, ok, R} -> ignore;
        {done, {error, Reason2}, R} ->
            ct:fail({out, Reason2})
    end,
    ok.

close_1() ->
    [].

close_1(Config) ->
    two_way(Config, test_close_in_1, test_close_out_1).

close_2() ->    
    [].

close_2(Config) ->
    two_way(Config, test_close_in_2, test_close_out_2).

close_3() ->
    [].

close_3(Config) ->
    two_way(Config, test_close_in_3, test_close_out_3).

backwards_communication() ->
    [].

backwards_communication(Config) ->
    two_way(Config, test_backwards_listen, test_backwards_connect).

full_duplex_communication() ->
    [].

full_duplex_communication(Config) ->
    two_way(Config, test_full_duplex_in, test_full_duplex_out).
    
connect_n_communicate() ->
    [].

connect_n_communicate(Config) ->
    C1 = ?config(connector, Config),
    C2 = ?config(connectee, Config),
    spawn(fun() ->
                  %% @todo, should fix this timer invocation
                  timer:sleep(3000),
                  rpc:call(C1, utp_test, test_connect_n_communicate_connect, [Config])
          end),
    {ok, _TR} = rpc:call(C2, utp_test, test_connect_n_communicate_listen, [Config]),
    ok.

rwin_test() ->
    [{timetrap, {seconds, 300}}].

rwin_test(Config) ->
    DataDir = ?config(data_dir, Config),
    {ok, FileData} = file:read_file(filename:join([DataDir, "test_large_send.dat"])),
    spawn_link(fun() ->
                       timer:sleep(3000),
                       {ok, TR} = rpc:call(?config(connector, Config),
                                           utp_test, test_rwin_out, [FileData, Config]),
                       ct:log("RWIN OUT:~n~p~n", [TR])
               end),
    {ok, TR} = rpc:call(?config(connectee, Config),
                        utp_test, test_rwin_in, [FileData, Config]),
    ct:log("RWIN IN:~n~p~n", [TR]),
    ok.
    
piggyback() ->
    [{timetrap, {seconds, 300}}].

piggyback(Config) ->
    DataDir = ?config(data_dir, Config),
    {ok, FileData} = file:read_file(filename:join([DataDir, "test_large_send.dat"])),
    {Controller, Ref} = {self(), make_ref()},
    spawn_link(fun() ->
                       timer:sleep(3000),
                       {ok, Socket1, TR} =
                           rpc:call(?config(connector, Config),
                                    utp_test, test_piggyback_out, [FileData, Config]),
                       ct:log("Piggyback out:~n~p~n", [TR]),
                       Controller ! {done, Ref, Socket1}
               end),
    {ok, Socket2, TR2} =
        rpc:call(?config(connectee, Config),
                 utp_test, test_piggyback_in, [FileData, Config]),
    ct:log("Piggyback out:~n~p~n", [TR2]),
    ct:log("All done, collecting sockets for closing"),
    receive
        {done, Ref, Socket1} ->
            ok = gen_utp:close(Socket1),
            ok = gen_utp:close(Socket2),
            ok
    end.

connect_n_send_big() ->
    [{timetrap, {seconds, 300}}].

connect_n_send_big(Config) ->
    DataDir = ?config(data_dir, Config),
    {ok, FileData} = file:read_file(filename:join([DataDir, "test_large_send.dat"])),
    spawn(fun() ->
                  timer:sleep(3000),
                  rpc:call(?config(connector, Config),
                           utp_test, test_send_large_file, [FileData, Config])
          end),
    {ok, _TR} = rpc:call(?config(connectee, Config),
                         utp_test, test_recv_large_file, [FileData, Config]),
    ok.

%% Helpers
%% ----------------------------------------------------------------------

start_node(Name,Port) ->
    {ok, ConnectNode} = test_server:start_node(Name, slave, []),
    ok = rpc:call(ConnectNode, utp, start_app, [Port]),
    ConnectNode.


