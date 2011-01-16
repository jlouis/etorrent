%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc Wrap a file-handle
%%
%% Server that wraps a file-handle and exposes an interface
%% that enables clients to read and write data at specified offsets.
%%
%% @end
-module(etorrent_io_file).
-behaviour(gen_server).
-include("types.hrl").
-define(GC_TIMEOUT, 5000).


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
    relpath  :: file_path(),
    fullpath :: file_path()}).


-define(CALL_TIMEOUT, timer:seconds(30)).

%% @doc Start the file wrapper server
%% <p>Of the two paths given, one is the partial path used internally
%% and the other is the full path where to store the file in question.</p>
%% @end
-spec start_link(torrent_id(), file_path(), file_path()) -> {'ok', pid()}.
start_link(TorrentID, Path, FullPath) ->
    gen_server:start_link(?MODULE, [TorrentID, Path, FullPath], [{spawn_opt, [{fullsweep_after, 0}]}]).

%% @doc Request to open the file
%% @end
-spec open(pid()) -> 'ok'.
open(FilePid) ->
    gen_server:cast(FilePid, open).

%% @doc Request to close the file
%% @end
-spec close(pid()) -> 'ok'.
close(FilePid) ->
    gen_server:cast(FilePid, close).

%% @doc Read bytes from file handle
%% <p>Read `Length' bytes from filehandle at `Offset'</p>
%% @end
-spec read(pid(), block_offset(), block_len()) ->
          {ok, block_bin()} | {error, eagain}.
read(FilePid, Offset, Length) ->
    gen_server:call(FilePid, {read, Offset, Length}, ?CALL_TIMEOUT).

%% @doc Write bytes to file
%% <p>Assume that the `Chunk' is of binary() type. Write it to the
%% file at `Offset'</p>
%% @end
-spec write(pid(), block_offset(), block_bin()) ->
          ok | {error, eagain}.
write(FilePid, Offset, Chunk) ->
    gen_server:call(FilePid, {write, Offset, Chunk}, ?CALL_TIMEOUT).

%% @private
init([TorrentID, RelPath, FullPath]) ->
    true = etorrent_io:register_file_server(TorrentID, RelPath),
    InitState = #state{
        torrent=TorrentID,
        handle=closed,
        relpath=RelPath,
        fullpath=FullPath},
    {ok, InitState}.

%% @private
handle_call({read, _, _}, _, State) when State#state.handle == closed ->
    {reply, {error, eagain}, State, ?GC_TIMEOUT};
handle_call({write, _, _}, _, State) when State#state.handle == closed ->
    {reply, {error, eagain}, State, ?GC_TIMEOUT};
handle_call({read, Offset, Length}, _, State) ->
    #state{handle=Handle} = State,
    {ok, Chunk} = file:pread(Handle, Offset, Length),
    {reply, {ok, Chunk}, State, ?GC_TIMEOUT};
handle_call({write, Offset, Chunk}, _, State) ->
    #state{handle=Handle} = State,
    ok = file:pwrite(Handle, Offset, Chunk),
    {reply, ok, State, ?GC_TIMEOUT}.

%% @private
handle_cast(open, State) ->
    #state{
        torrent=Torrent,
        handle=closed,
        relpath=RelPath,
        fullpath=FullPath} = State,
    true = etorrent_io:register_open_file(Torrent, RelPath),
    FileOpts = [read, write, binary, raw, read_ahead,
                {delayed_write, 1024*1024, 3000}],
    ok = filelib:ensure_dir(FullPath),
    {ok, Handle} = file:open(FullPath, FileOpts),
    NewState = State#state{handle=Handle},
    {noreply, NewState, ?GC_TIMEOUT};

handle_cast(close, State) ->
    #state{
        torrent=Torrent,
        handle=Handle,
        relpath=RelPath} = State,
    true = etorrent_io:unregister_open_file(Torrent, RelPath),
    ok = file:close(Handle),
    NewState = State#state{handle=closed},
    {noreply, NewState, ?GC_TIMEOUT}.

%% @private
handle_info(timeout, State) ->
    true = erlang:garbage_collect(),
    {noreply, State}.

%% @private
terminate(_, _) ->
    not_implemented.

%% @private
code_change(_, _, _) ->
    not_implemented.
