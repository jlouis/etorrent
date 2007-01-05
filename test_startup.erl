-module(test_startup).

-compile(export_all).

start() ->
    crypto:start(),
    inets:start(),
    etorrent:start_link("./test/").
