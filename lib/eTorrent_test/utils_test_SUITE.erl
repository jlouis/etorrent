%%%-------------------------------------------------------------------
%%% File    : utils_test_SUITE.erl
%%% Author  : User Jlouis <jlouis@succubus.localdomain>
%%% Description : Test utilities
%%%
%%% Created : 17 Apr 2007 by User Jlouis <jlouis@succubus.localdomain>
%%%-------------------------------------------------------------------
-module(utils_test_SUITE).

-export([all/1, test_read_all_of_file/1]).

-include("test_server.hrl").

all(doc) ->
    ["Test the various utility functions"];

all(suite) ->
    [test_read_all_of_file];

all(Config) when is_list(Config) ->
    ok.
%% Test cases starts here.
%%--------------------------------------------------------------------
test_read_all_of_file(doc) ->
    ["Test we can read files in full"];
test_read_all_of_file(suite) ->
    [];
test_read_all_of_file(Config) when is_list(Config) ->
    ?line ExpectedData = "1234567890",
    ?line {ok, Data} = utils:read_all_of_file("utils_test_SUITE_data/dummy_file.txt"),
    ?line Data = ExpectedData,
    ok.

