%% @author Magnus Klaar <magnus.klaar@gmail.com>
%% @doc File I/O Request supervisor
%% <p>
%% All file I/O requests are performed by a supervised process running under
%% this supervisor process. Failed I/O requests are retried until success.
%% </p>
%% @end
-module(etorrent_io_req_sup).
-behaviour(supervisor).

%% exported functions
-export([start_link/2,
         start_read/4,
         start_write/5]).

%% supervisor callbacks
-export([init/1]).


%% @doc Start the file I/O request supervisor.
%% @end
start_link(TorrentID, Operation) ->
    supervisor:start_link(?MODULE, [TorrentID, Operation]).


%% @doc Start a read operation.
%% @end
start_read(TorrentID, Piece, Offset, Length) ->
    Pid = etorrent_utils:await({etorrent_io_req_sup,read,TorrentID}, infinity),
    supervisor:start_child(Pid, [Piece, Offset, Length, self()]).

%% @doc Start a write operation.
%% @end
start_write(TorrentID, Piece, Offset, Length, Chunk) ->
    Pid = etorrent_utils:await({etorrent_io_req_sup,write,TorrentID}, infinity),
    supervisor:start_child(Pid, [Piece, Offset, Length, Chunk, self()]).

%% @private
init([TorrentID, Operation]) ->
    etorrent_utils:register({etorrent_io_req_sup, Operation, TorrentID}),
    Dirpid = etorrent_io:await_directory(TorrentID),
    ReqSpec = request_spec(TorrentID, Dirpid, Operation),
    {ok, {{simple_one_for_one, 1, 60}, [ReqSpec]}}.

%% @private
request_spec(TorrentID, Dirpid, read) ->
    read_request_spec(TorrentID, Dirpid);
request_spec(TorrentID, Dirpid, write) ->
    write_request_spec(TorrentID, Dirpid).

%% @private
read_request_spec(TorrentID, Dirpid) ->
    {undefined,
        {etorrent_io_req, start_read, [TorrentID, Dirpid]},
        transient, 2000, worker, [etorrent_io_req]}.

%% @private
write_request_spec(TorrentID, Dirpid) ->
    {undefined,                                                    
        {etorrent_io_req, start_write, [TorrentID, Dirpid]},
        transient, 2000, worker, [etorrent_io_req]}.
