-module(utp_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([suite/0, all/0, groups/0,
	 init_per_group/2, end_per_group/2,
	 init_per_suite/1, end_per_suite/1,
	 init_per_testcase/2, end_per_testcase/2]).

-export([connect/0, connect/1]).

suite() ->
    [{timetrap, {minutes, 3}}].

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

init_per_testcase(connect, Config) ->
    Config.

init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(_Case, _Config) ->
    ok.


%% Tests
%% ----------------------------------------------------------------------
groups() ->
    [{main_group, [shuffle], [connect]}].

all() ->
    [{group, main_group}].

connect() ->
    [].

connect(Config) ->
    
    ok.

%% Helpers
%% ----------------------------------------------------------------------

