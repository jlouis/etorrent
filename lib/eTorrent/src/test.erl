-module(test).

-compile(export_all).

start() ->
    crypto:start(),
    inets:start(),
    application:set_env(etorrent, dir, "/home/jlouis/etorrent_test"),
    error_logger:logfile({open, "err.log"}),
    etorrent:start_link().
