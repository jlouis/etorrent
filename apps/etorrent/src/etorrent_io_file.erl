-module(etorrent_io_file).
-behaviour(gen_server).
-include("types.hrl").

%%
%% Server that wraps a file-handle and exposes an interface
%% that enables clients to read and write data at specified offsets.
%%

-export([start_link/3,
         open/1,
         close/1,
         read/3,
         write/3]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {
    torrent :: torrent_id(),
    handle=closed :: closed | file:io_device(),
    relpath :: file_path(),
    fullpath :: file_path(),
    dir_monitor=none :: none | reference(),
    await_ref=none :: none | reference()}).


-spec start_link(torrent_id(), file_path(), file_path()) -> {'ok', pid()}.
start_link(TorrentID, Path, FullPath) ->
    gen_server:start_link(?MODULE, [TorrentID, Path, FullPath], []).

-spec open(pid()) -> 'ok'.
open(FilePid) ->
    gen_server:cast(FilePid, open).

-spec close(pid()) -> 'ok'.
close(FilePid) ->
    gen_server:cast(FilePid, close).

-spec read(pid(), block_offset(), block_len()) ->
          {ok, block_bin()} | {error, eagain}.
read(FilePid, Offset, Length) ->
    gen_server:call(FilePid, {read, Offset, Length}).

-spec write(pid(), block_offset(), block_bin()) ->
          ok | {error, eagain}.
write(FilePid, Offset, Chunk) ->
    gen_server:call(FilePid, {write, Offset, Chunk}).

init([TorrentID, RelPath, FullPath]) ->
    {ok, DirPid} = etorrent_io:await_directory(TorrentID),
    DirMonitor = erlang:monitor(process, DirPid),
    _ = etorrent_io:register_file_server(TorrentID, RelPath),
    InitState = #state{
        torrent=TorrentID,
        handle=closed,
        relpath=RelPath,
        fullpath=FullPath,
        dir_monitor=DirMonitor,
        await_ref=none},
    {ok, InitState}.

handle_call({read, _, _}, _, State) when State#state.handle == closed ->
    {reply, {error, eagain}, State};
handle_call({write, _, _}, _, State) when State#state.handle == closed ->
    {reply, {error, eagain}, State};
handle_call({read, Offset, Length}, _, State) ->
    #state{handle=Handle} = State,
    {ok, Chunk} = file:pread(Handle, Offset, Length),
    {reply, {ok, Chunk}, State};
handle_call({write, Offset, Chunk}, _, State) ->
    #state{handle=Handle} = State,
    ok = file:pwrite(Handle, Offset, Chunk),
    {reply, ok, State}.

handle_cast(open, State) when State#state.dir_monitor =/= none ->
    #state{
        torrent=Torrent,
        handle=closed,
        relpath=RelPath,
        fullpath=FullPath} = State,
    _ = etorrent_io:register_open_file(Torrent, RelPath),
    FileOpts = [read, write, binary, raw, read_ahead,
                {delayed_write, 1024*1024, 3000}],
    {ok, Handle} = file:open(FullPath, FileOpts),
    NewState = State#state{handle=Handle},
    {noreply, NewState};

handle_cast(close, State) when State#state.dir_monitor =/= none ->
    #state{
        torrent=Torrent,
        handle=Handle,
        relpath=RelPath} = State,
    _ = etorrent_io:unregister_open_file(Torrent, RelPath),
    ok = file:close(Handle),
    NewState = #state{handle=closed},
    {noreply, NewState}.

handle_info({'DOWN', DirMon, _, _, _}, State)
when DirMon == State#state.dir_monitor ->
    #state{
        torrent=Torrent,
        handle=Handle} = State,
    AwaitRef = erlang_io:await_new_directory(Torrent),
    case Handle of
        closed ->
            NewState = State#state{
                dir_monitor=none,
                await_ref=AwaitRef},
            {noreply, NewState};
        Handle ->
            ok = file:close(Handle),
            NewState = State#state{
                handle=closed,
                dir_monitor=none,
                await_ref=AwaitRef},
            {noreply, NewState}
    end;

handle_info({gproc, AwaitRef, registered, {_, DirPid, _}}, State)
when AwaitRef == State#state.await_ref ->
    DirMon = erlang:monitor(process, DirPid),
    NewState = #state{
        dir_monitor=DirMon,
        await_ref=none},
    {noreply, NewState}.



terminate(_, _) ->
    not_implemented.

code_change(_, _, _) ->
    not_implemented.
