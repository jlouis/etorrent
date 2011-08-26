-module(etorrent_rlimit).
%% This module wraps the rlimit application and exports functions that
%% are expected to be called from etorrent_peer_send and etorrent_peer_recv.
%%
%% etorrent_peer_send is expected to aquire a slot before a message is sent.
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
    ok = rlimit:new(?DOWNLOAD, DLRate, 1000),
    ok = rlimit:new(?UPLOAD, ULRate, 1000).

%% @doc Aquire a send slot.
%% @end
-spec send(non_neg_integer()) -> ok.
send(Bytes) ->
    rlimit:take(Bytes, ?UPLOAD).


%% @doc Aquire a receive slot.
%% @end
-spec recv(non_neg_integer()) -> ok.
recv(Bytes) ->
    rlimit:take(Bytes, ?DOWNLOAD).
