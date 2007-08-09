-module(test).

-compile(export_all).

start() ->
    start_sasl(),
    application:start(crypto),
    application:start(inets),
    application:start(timer),
    application:set_env(etorrent, dir, "/home/jlouis/etorrent_test"),
    application:set_env(etorrent, port, 1729),
    etorrent:start_link().

start_sasl() ->
    application:set_env(sasl, errlog_type, all),
    application:set_env(sasl, error_logger_mf_dir, "error_logs"),
    application:set_env(sasl, error_logger_mf_maxbytes, 1024*1024*5),
    application:set_env(sasl, error_logger_mf_maxfiles, 10),
    application:start(sasl).

start_rb() ->
    application:start(sasl),
    rb:start([{report_dir, "error_logs"}]).

run() ->
    etorrent:start_link().
