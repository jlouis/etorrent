%% @author Magnus Klaar <magnus.klaar@gmail.com>
%% @doc File I/O Request Process.
%% <p>
%% All file I/O operations are performed in a process different from the
%% client process requesting a read or write operation from the IO subsystem.
%% </p>
%% @end
-module(etorrent_io_req).

%% exported functions
-export([start_read/6,
         start_write/7]).

%% internal functions
-export([execute_read/6,
         execute_write/7]).


%% @doc Start a read request process.
%% On success the chunk is sent to the client process.
%% @end
start_read(TorrentID, Dirpid, Piece, Offset, Length, ClientPid) ->
    Args = [TorrentID, Dirpid, Piece, Offset, Length, ClientPid],
    proc_lib:start_link(?MODULE, execute_read, Args).


%% @doc Start a write request process.
%% On success an acknowledgement is sent to the client process.
%% @end
start_write(TorrentID, Dirpid, Piece, Offset, Length, Chunk, ClientPid) ->
    Args = [TorrentID, Dirpid, Piece, Offset, Length, Chunk, ClientPid],
    proc_lib:start_link(?MODULE, execute_write, Args).


%% @private Execute a read request.
execute_read(_TorrentID, Dirpid, Piece, Offset, Length, ClientPid) ->
    ok = proc_lib:init_ack({ok, self()}),
    {ok, Chunk} = etorrent_io:read_chunk(Dirpid, Piece, Offset, Length),
    ok = etorrent_chunkstate:contents(Piece, Offset, Length, Chunk, ClientPid).


%% @private Execute a write request.
execute_write(_TorrentID, Dirpid, Piece, Offset, Length, Chunk, ClientPid) ->
    ok = proc_lib:init_ack({ok, self()}),
    ok = etorrent_io:write_chunk(Dirpid, Piece, Offset, Chunk),
    ok = send_ack(Piece, Offset, Length, ClientPid).

%% @private Send an acknowledgement as the response to a write request.
send_ack(Piece, Offset, Length, ClientPid) ->
    ClientPid ! {chunk, {written, Piece, Offset, Length}},
    ok.
