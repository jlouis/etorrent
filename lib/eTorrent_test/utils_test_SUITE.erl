%%%-------------------------------------------------------------------
%%% File    : utils_test_SUITE.erl
%%% Author  : User Jlouis <jlouis@succubus.localdomain>
%%% Description : Test utilities
%%%
%%% Created : 17 Apr 2007 by User Jlouis <jlouis@succubus.localdomain>
%%%-------------------------------------------------------------------
-module(utils_test_SUITE).

-compile(export_all).

-include("test_server.hrl").

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

all(doc) ->
    ["Test the various utility functions"];

all(suite) ->
    [utils].

utils(doc) ->
    ["Test utility functions"];
utils(suite) ->
    [test_read_all_of_file].

%% Test cases starts here.
%%--------------------------------------------------------------------
test_read_all_of_file(doc) ->
    ["Test we can read files"];
test_read_all_of_file(suite) ->
    [];
test_read_all_of_file(Config) when is_list(Config) ->
    ?line {ok, Data} = utils:read_all_of_file(
			 "utils_test_SUITE_data/dummy_file.txt"),
    ?line ExpectedData = "1234567890",
    ?line Data = ExpectedData,
    ok.

