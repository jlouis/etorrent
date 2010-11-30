-module(etorrent_io_file).
-behaviour(gen_server).
-include("types.hrl").

%%
%% Server that wraps a file-handle and exposes an interface
%% that enables clients to read and write data at specified offsets.
%%

-export([start_link/3,
         read/3,
         write/3]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).


-spec start_link(torrent_id(), file_path(), file_path()) -> {'ok', pid()}.
start_link(TorrentID, Path, FullPath) ->
    gen_server:start_link(?MODULE, [TorrentID, Path, FullPath], []).

-spec read(pid(), block_offset(), block_len()) -> {ok, block_bin()}.
read(FilePid, Offset, Length) ->
    gen_server:call(FilePid, {read, Offset, Length}).

-spec write(pid(), block_offset(), block_bin()) -> 'ok'.
write(FilePid, Offset, Chunk) ->
    gen_server:call(FilePid, {write, Offset, Chunk}).

init([TorrentID, Path, FullPath]) ->
    etorrent_io:register_file_server(TorrentID, Path),
    FileOpts = [read, write, binary, raw,
                read_ahead, {delayed_write, 1024*1024, 3000}],
    {ok, FD} = file:open(FullPath, FileOpts).

handle_call({read, Offset, Length}, _, FD) ->
    {ok, Chunk} = file:pread(FD, Offset, Length),
    {reply, {ok, Chunk}, FD};
handle_call({write, Offset, Chunk}, _, FD) ->
    ok = file:pwrite(FD, Offset, Chunk),
    {reply, ok, FD}.

handle_cast(_, State) ->
    {noreply, State}.

handle_info(_, State) ->
    {noreply, State}.

terminate(_, _) ->
    not_implemented.

code_change(_, _, _) ->
    not_implemented.
