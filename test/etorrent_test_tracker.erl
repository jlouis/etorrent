-module(etorrent_test_tracker).

-export([tracker_callback/0]).


tracker_callback() ->
    file:write_file("init", <<"hello">>),
    ok.
