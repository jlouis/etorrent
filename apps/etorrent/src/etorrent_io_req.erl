%% @author Magnus Klaar <magnus.klaar@gmail.com>
%% @doc File I/O Request Process.
%% <p>
%% All file I/O operations are performed in a process different from the
%% client process requesting a read or write operation from the IO subsystem.
%% </p>
%% @end
-module(etorrent_io_req).


%% exported functions
-export([start_link/5]).

%% internal functions
-export([execute/5]).


%% @doc Start a new IO-request process.
%% - When all blocks have been read the blocks are sent as a chunk to the client
%% - When all blocks have been written a notification is sent to the client
%% @end
start_link(TorrentID, Piece, Offset, Length, ClientPid) ->
    Args = [TorrentID, Piece, Offset, Length, ClientPid],
    proc_lib:spawn_link(?MODULE, execute, Args).


%% @private Execute an IO-request.
execute(TorrentID, Piece, Offset, Length, ClientPid) ->
    ok = proc_lib:init_ack({ok, self()}),
    {ok, Chunk} = etorrent_io:read_chunk(TorrentID, Piece, Offset, Length),
    ok = send_chunk(Piece, Offset, Length, Chunk, ClientPid).


%% @private Send a data chunk as the response to a read request.
send_chunk(Piece, Offset, Length, Chunk, ClientPid) ->
    ClientPid ! {chunk, {data, Piece, Offset, Length, Chunk}},
    ok.
