-module(test).

-compile(export_all).

start() ->
    crypto:start(),
    inets:start(),
    timer:start(),
    %http:set_options([{verbose, debug}]),
    application:set_env(etorrent, dir, "/home/jlouis/etorrent_test"),
    application:set_env(etorrent, port, 1729),
    error_logger:logfile({open, "err.log"}),
    etorrent:start_link().


run() ->
    error_logger:logfile(close),
    error_logger:logfile({open, "err.log"}),
    etorrent:start_link().
