-module(utils_test).

-include_lib("eunit/include/eunit.hrl").

read_all_of_file_test() ->
    {ok, "1234567890\n"} = utils:read_all_of_file("test_data/123.txt"),
    {error, enoent} = utils:read_all_of_file("test_data/nonexisting").




