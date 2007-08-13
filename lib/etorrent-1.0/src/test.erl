-module(test).

-compile(export_all).

start_apps() ->
    start_sasl(),
    application:start(crypto),
    application:start(inets),
    application:start(timer),
    application:setorrent_env(etorrent, dir, "/home/jlouis/etorrent_test"),
    application:setorrent_env(etorrent, port, 1729).

start() ->
    start_apps(),
    etorrent:start_link().

start_sasl() ->
    application:setorrent_env(sasl, sasl_error_logger, {file, "err.log"}),
    application:setorrent_env(sasl, errlog_type, all),
    application:setorrent_env(sasl, error_logger_mf_dir, "error_logs"),
    application:setorrent_env(sasl, error_logger_mf_maxbytes, 5000000),
    application:setorrent_env(sasl, error_logger_mf_maxfiles, 10),
    sasl:start(normal, []).

start_rb() ->
    application:start(sasl),
    rb:start([{report_dir, "error_logs"}]).

run() ->
    etorrent:start_link().
