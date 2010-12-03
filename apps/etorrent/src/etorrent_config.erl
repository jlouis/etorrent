-module(etorrent_config).
-include("types.hrl").
-compile(export_all).

required(Key) ->
    {ok, Value} = application:get_env(etorrent, Key),
    Value.

optional(Key, Default) ->
    case application:get_env(etorrent, Key) of
        {ok, Value} ->
            Value;
        undefined ->
            Default
    end.

-spec work_dir() -> file_path().
work_dir() -> required(dir).

-spec fast_resume_file() -> file_path().
fast_resume_file() -> required(fast_resume_file).

-spec udp_port() -> pos_integer().
udp_port() -> required(udp_port).

-spec max_peers() -> pos_integer().
max_peers() -> optional(max_peers, 40).

-spec webui() -> boolean().
webui() -> required(webui).

-spec profiling() -> boolean().
profiling() -> required(profiling).

-spec webui_port() -> pos_integer().
webui_port() -> required(webui_port).

-spec webui_address() -> inet:ip_address().
webui_address() -> required(webui_bind_address).

-spec webui_log_dir() -> file_path().
webui_log_dir() -> required(webui_logger_dir).

-spec max_files() -> pos_integer().
max_files() -> optional(fs_watermark_high, 128).

-spec max_upload_slots() -> auto | pos_integer().
max_upload_slots() -> optional(max_upload_slots, upload).

-spec optimistic_slots() -> pos_integer().
optimistic_slots() -> required(min_upload).

-spec max_upload_rate() -> pos_integer().
max_upload_rate() -> required(max_upload_rate).

-spec listen_port() -> pos_integer().
listen_port() -> required(port).

-spec logger_dir() -> file_path().
logger_dir() -> required(logger_dir).

-spec logger_file() -> file_path().
logger_file() -> required(logger_fname).

-spec dht() -> boolean().
dht() -> optional(dht, false).

-spec dht_port() -> pos_integer().
dht_port() -> optional(dht_port, 6882).

-spec dht_state_file() -> file_path().
dht_state_file() -> optional(dht_state, "etorrent_dht_state").
