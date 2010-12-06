-module(etorrent_io_file_sup).
-behaviour(supervisor).
-include("types.hrl").

%% Use a separate supervisor for files. This ensures that
%% the directory server can assume that all files will be
%% closed if it crashes.

-export([start_link/3]).
-export([init/1]).

-spec start_link(torrent_id(), file_path(), list(file_path())) -> {'ok', pid()}.
start_link(TorrentID, TorrentFile, Files) ->
    supervisor:start_link(?MODULE, [TorrentID, TorrentFile, Files]).

init([TorrentID, Workdir, Files]) ->
    FileSpecs  = [file_server_spec(TorrentID, Workdir, Path) || Path <- Files],
    {ok, {{one_for_all, 1, 60}, FileSpecs}}.

file_server_spec(TorrentID, Workdir, Path) ->
    Fullpath = filename:join(Workdir, Path),
    {{TorrentID, Path},
        {etorrent_io_file, start_link, [TorrentID, Path, Fullpath]},
        permanent, 2000, worker, [etorrent_io_file]}.
