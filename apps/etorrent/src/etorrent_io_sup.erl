%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc Supervise a set of file system processes
%% <p>This supervisor is responsible for overseeing the file system
%% processes for a single torrent.</p>
%% @end
-module(etorrent_io_sup).
-behaviour(supervisor).
-include("types.hrl").

-export([start_link/2]).
-export([init/1]).

%% @doc Initiate the supervisor.
%% <p>The arguments are the ID of the torrent and the file-path at
%% which the torrent file lives</p>
%% @end
-spec start_link(torrent_id(), file_path()) -> {'ok', pid()}.
start_link(TorrentID, TorrentFile) ->
    supervisor:start_link(?MODULE, [TorrentID, TorrentFile]).

%% ----------------------------------------------------------------------

%% @private
init([TorrentID, TorrentFile]) ->
    Workdir   = etorrent_config:work_dir(),
    FullPath  = filename:join([Workdir, TorrentFile]),
    Torrent   = etorrent_bcoding:parse_file(FullPath),
    Files     = etorrent_metainfo:file_paths(Torrent),
    DirServer = directory_server_spec(TorrentID, Torrent),
    FileSup   = file_server_sup_spec(TorrentID, Workdir, Files),
    {ok, {{one_for_one, 1, 60}, [DirServer, FileSup]}}.

%% ----------------------------------------------------------------------
directory_server_spec(TorrentID, Torrent) ->
    {{TorrentID, directory},
        {etorrent_io, start_link, [TorrentID, Torrent]},
        permanent, 2000, worker, [etorrent_io]}.

file_server_sup_spec(TorrentID, Workdir, Files) ->
    Args = [TorrentID, Workdir, Files],
    {{TorrentID, file_server_sup},
        {etorrent_io_file_sup, start_link, Args},
        permanent, 2000, supervisor, [etorrent_file_io_sup]}.
