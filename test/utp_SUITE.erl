-module(utp_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([suite/0, all/0, groups/0,
	 init_per_group/2, end_per_group/2,
	 init_per_suite/1, end_per_suite/1,
	 init_per_testcase/2, end_per_testcase/2]).

-export([connect_n_communicate/0, connect_n_communicate/1]).

suite() ->
    [{timetrap, {seconds, 20}}].

%% Setup/Teardown
%% ----------------------------------------------------------------------
init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_suite(Config) ->
    {ok, ConnectNode} = test_server:start_node('connector', slave, []),
    {ok, ConnecteeNode} = test_server:start_node('connectee', slave, []),
    [{connector, ConnectNode},
     {connectee, ConnecteeNode} | Config].

end_per_suite(Config) ->
    test_server:stop_node(?config(connector, Config)),
    test_server:stop_node(?config(connectee, Config)),
    ok.

init_per_testcase(connect_n_communicate, Config) ->
    Config;
init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(_Case, _Config) ->
    ok.


%% Tests
%% ----------------------------------------------------------------------
groups() ->
    [{main_group, [shuffle], [connect_n_communicate]}].

all() ->
    [{group, main_group}].

connect_n_communicate() ->
    [].

connect_n_communicate(Config) ->
    C1 = ?config(connector, Config),
    C2 = ?config(connectee, Config),
    {Pid, Ref} = {self(), make_ref()},
    spawn(fun() ->
                  %% @todo, should fix this timer invocation
                  timer:sleep(3000),
                  rpc:call(C1, utp, connector1, [])
          end),
    {<<"HELLO">>, <<"WORLD">>} = rpc:call(C2, utp, connectee1, []),
    ok.

%% Helpers
%% ----------------------------------------------------------------------

