-module(test_startup).

-compile(export_all).

start() ->
    crypto:start(),
    inets:start(),
    torrent_manager:start(),
    dirwatcher:start("./test/").
