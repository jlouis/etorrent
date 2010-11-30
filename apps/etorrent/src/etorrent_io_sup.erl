-module(etorrent_io_sup).
-behaviour(supervisor).
-include("types.hrl").

-export([start_link/2]).
-export([init/1]).

-spec start_link(torrent_id(), file_path()) -> {'ok', pid()}.
start_link(TorrentID, TorrentFile) ->
    supervisor:start_link(?MODULE, [TorrentID, TorrentFile]).

init([TorrentID, TorrentFile]) ->
    {ok, Workdir} = application:get_env(etorrent, dir),
    FullPath = filename:join([Workdir, TorrentFile]),
    io:format(FullPath, []),
    Torrent    = etorrent_bcoding:parse_file(FullPath),
    Files      = etorrent_io:file_paths(Torrent),
    FileSpecs  = [file_server_spec(TorrentID, Workdir, Path) || Path <- Files],
    DirSpec    = directory_server_spec(TorrentID, Torrent),
    {ok, {{one_for_one, 1, 60}, FileSpecs ++ [DirSpec]}}.

file_server_spec(TorrentID, Workdir, Path) ->
    Fullpath = filename:join(Workdir, Path),
    {{TorrentID, Path},
        {etorrent_io_file, start_link, [TorrentID, Path, Fullpath]},
        transient, 2000, worker, [etorrent_io_file]}.

directory_server_spec(TorrentID, Torrent) ->
    {{TorrentID, directory},
        {etorrent_io, start_link, [TorrentID, Torrent]},
        transient, 2000, worker, [etorrent_io]}.
