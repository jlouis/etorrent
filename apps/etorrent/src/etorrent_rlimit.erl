-module(etorrent_rlimit).
%% This module wraps the rlimit application and exports functions that
%% are expected to be called from etorrent_peer_send and etorrent_peer_recv.
%%
%% etorrent_peer_send is expected to aquire a slot after a message is sent.
%% etorrent_peer_recv is expected to aquire a slot after receiving a message.
-export([init/0, send/1, recv/1]).

%% flow name definitions
-define(DOWNLOAD, etorrent_download_rlimit).
-define(UPLOAD, etorrent_upload_rlimit).


%% @doc Initialize the download and upload flows.
%% @end
-spec init() -> ok.
init() ->
    DLRate = etorrent_config:max_download_rate(),
    ULRate = etorrent_config:max_upload_rate(),
    ok = rlimit:new(?DOWNLOAD, to_byte_rate(DLRate), 1000),
    ok = rlimit:new(?UPLOAD, to_byte_rate(ULRate), 1000).

%% @doc Aquire a send slot.
%% A continue message will be sent to the caller once a slot has been aquired.
%% @end
-spec send(non_neg_integer()) -> ok.
send(Bytes) ->
    rlimit:atake(Bytes, {rlimit, continue}, ?UPLOAD).


%% @doc Aquire a receive slot.
%% A continue message will be sent to the caller once a slot has been aquired.
%% @end
-spec recv(non_neg_integer()) -> ok.
recv(Bytes) ->
    rlimit:atake(Bytes, {rlimit, continue}, ?DOWNLOAD).

%% @private Convert KB/s to B/s
to_byte_rate(infinity) ->
    infinity;
to_byte_rate(KB) ->
    1024 * KB.
