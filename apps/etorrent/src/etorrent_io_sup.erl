%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc Supervise a set of file system processes
%% <p>This supervisor is responsible for overseeing the file system
%% processes for a single torrent.</p>
%% @end
-module(etorrent_io_sup).
-behaviour(supervisor).

-export([start_link/2]).
-export([init/1]).

-type bcode() :: etorrent_types:bcode().
-type torrent_id() :: etorrent_types:torrent_id().


%% @doc Initiate the supervisor.
%% <p>The arguments are the ID of the torrent and the
%% parsed torrent file</p>
%% @end
-spec start_link(torrent_id(), bcode()) -> {'ok', pid()}.
start_link(TorrentID, Torrent) ->
    supervisor:start_link(?MODULE, [TorrentID, Torrent]).

%% ----------------------------------------------------------------------

%% @private
init([TorrentID, Torrent]) ->
    Files     = etorrent_metainfo:file_paths(Torrent),
    DirServer = directory_server_spec(TorrentID, Torrent),
    Dldir     = etorrent_config:download_dir(),
    FileSup   = file_server_sup_spec(TorrentID, Dldir, Files),
    ReadSup   = requests_sup_spec(TorrentID, read),
    WriteSup  = requests_sup_spec(TorrentID, write),
    {ok, {{one_for_one, 1, 60}, [DirServer, FileSup, ReadSup, WriteSup]}}.

%% ----------------------------------------------------------------------
directory_server_spec(TorrentID, Torrent) ->
    {{TorrentID, directory},
        {etorrent_io, start_link, [TorrentID, Torrent]},
        permanent, 2000, worker, [etorrent_io]}.

file_server_sup_spec(TorrentID, Workdir, Files) ->
    Args = [TorrentID, Workdir, Files],
    {{TorrentID, file_server_sup},
        {etorrent_io_file_sup, start_link, Args},
        permanent, 2000, supervisor, [etorrent_io_file_sup]}.

requests_sup_spec(TorrentID, Operation) ->
    {{TorrentID, request_sup, Operation},
        {etorrent_io_req_sup, start_link, [TorrentID, Operation]},
        permanent, 2000, supervisor, [etorrent_io_req_sup]}.
