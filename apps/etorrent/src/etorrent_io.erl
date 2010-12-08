-module(etorrent_io).
-behaviour(gen_server).
-include("types.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(AWAIT_TIMEOUT, 10*1000).

%%
%% #File I/O subsystem.
%%
%% A directory server (this module) is responsible for maintaining
%% the opened/closed state for each file in a torrent.
%%
%% ## Pieces
%% The directory server is responsible for mapping each piece to a set
%% of file-blocks. A piece is only mapped to multiple blocks if it spans
%% multiple files.
%%
%% ## Chunks
%% Chunks are mapped to a set of file blocks based on the file blocks that
%% contain the piece that the chunk is a member of.
%%
%% ## Scheduling
%% Because there is a limit on the number of file descriptors that an
%% OS-process can have open at the same time the directory server
%% attempts to limit the amount of file servers that hold an actual
%% file handle to the file it is resonsible for.
%%
%% Each time a client intends to read/write to a file it notifies the
%% directory server. If the file is not a member of the set of open files
%% the server the file server to open a file handle to the file.
%% 
%% When the limit on file servers keeping open file handles has been reached
%% the file server will notify the least recently used file server to close
%% its file handle for each notification for a file that is not in the set
%% of open files.
%%
%% ## Guarantees
%% The protocol between the directory server and the file servers is
%% asynchronous, there is no guarantee that the number of open file handles
%% will never be larger than the specified number.
%%
%% ## Synchronization
%% The gproc application is used to keep a registry of the process ids of
%% directory servers and file servers. A file server registers under a second
%% name when it has an open file handle. The support in gproc for waiting until a
%% name is registered is used to notify clients when the file server has an
%% open file handle.
%%
-export([start_link/2,
         read_piece/2,
         read_chunk/4,
         write_chunk/4,
         file_paths/1,
         register_directory/1,
         lookup_directory/1,
         await_directory/1,
         register_file_server/2,
         lookup_file_server/2,
         register_open_file/2,
         unregister_open_file/2,
         await_open_file/2]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).


-type block_pos() :: {string(), block_offset(), block_len()}.

-record(io_file, {
    rel_path :: file_path(),
    process  :: pid(),
    monitor  :: reference(),
    accessed :: {integer(), integer(), integer()}}).

-record(state, {
    torrent :: torrent_id(),
    pieces  :: array(),
    files_open :: list(#io_file{}),
    files_max  :: pos_integer()}).

%%
%% TODO - comment and spec
%%
-spec start_link(torrent_id(), bcode()) -> {'ok', pid()}.
start_link(TorrentID, Torrent) ->
    gen_server:start_link(?MODULE, [TorrentID, Torrent], []).


%% @doc
%% Read a piece into memory from disc.
%% @end
-spec read_piece(torrent_id(), piece_index()) -> {'ok', piece_bin()}.
read_piece(TorrentID, Piece) ->
    {ok, DirPid} = await_directory(TorrentID),
    {ok, Positions} = get_positions(DirPid, Piece),
    BlockList = read_file_blocks(TorrentID, Positions),
    {ok, iolist_to_binary(BlockList)}.


%% @doc
%% Read a chunk from a piece by reading each of the file
%% blocks that make up the chunk and concatenating them.
%% @end
-spec read_chunk(torrent_id(), piece_index(),
                 chunk_offset(), chunk_len()) -> {'ok', chunk_bin()}.
read_chunk(TorrentID, Piece, Offset, Length) ->
    {ok, DirPid} = await_directory(TorrentID),
    {ok, Positions} = get_positions(DirPid, Piece),
    ChunkPositions  = chunk_positions(Offset, Length, Positions),
    BlockList = read_file_blocks(TorrentID, ChunkPositions),
    {ok, iolist_to_binary(BlockList)}.

%% @doc
%% Write a chunk to a piece by writing parts of the block
%% to each file that the block occurs in.
%% @end
-spec write_chunk(torrent_id(), piece_index(),
                  chunk_offset(), chunk_bin()) -> 'ok'.
write_chunk(TorrentID, Piece, Offset, Chunk) ->
    {ok, DirPid} = await_directory(TorrentID),
    {ok, Positions} = get_positions(DirPid, Piece),
    Length = byte_size(Chunk),
    ChunkPositions = chunk_positions(Offset, Length, Positions),
    ok = write_file_blocks(TorrentID, Chunk, ChunkPositions).


%% @doc
%% Read a list of block sequentially from the file
%% servers in this directory responsible for each path the
%% is included in the list of positions.
%% @end
-spec read_file_blocks(torrent_id(), list(block_pos())) -> iolist().
read_file_blocks(_, []) ->
    [];
read_file_blocks(TorrentID, [{Path, Offset, Length}|T]=L) ->
    ok = schedule_io_operation(TorrentID, Path),
    {ok, FilePid} = await_open_file(TorrentID, Path),
    case etorrent_io_file:read(FilePid, Offset, Length) of
        {error, eagain} ->
            %% XXX - potential race condition
            read_file_blocks(TorrentID, L);
        {ok, Block} ->
            [Block|read_file_blocks(TorrentID, T)]
    end.

%% @doc
%% Write a list of blocks of a chunk seqeuntially to the file servers
%% in this directory responsible for each path that is included
%% in the lists of positions at which the block appears.
%% @end
-spec write_file_blocks(torrent_id(), chunk_bin(), list(block_pos())) -> 'ok'.
write_file_blocks(_, <<>>, []) ->
    ok;
write_file_blocks(TorrentID, Chunk, [{Path, Offset, Length}|T]=L) ->
    ok = schedule_io_operation(TorrentID, Path),
    {ok, FilePid} = await_open_file(TorrentID, Path),
    <<Block:Length/binary, Rest/binary>> = Chunk,
    case etorrent_io_file:write(FilePid, Offset, Block) of
        {error, eagain} ->
            write_file_blocks(TorrentID, Chunk, L);
        ok ->
            write_file_blocks(TorrentID, Rest, T)
    end.

file_path_len(T) ->
    case etorrent_metainfo:get_files(T) of
	[One] -> [One];
	More when is_list(More) ->
	    Name = etorrent_metainfo:get_name(T),
	    [{filename:join([Name, Path]), Len} || {Path, Len} <- More]
    end.

file_paths(T) ->
    [Path || {Path, _} <- file_path_len(T)].

%% @doc
%% Register the current process as the directory server for
%% the given torrent.
%% @end
-spec register_directory(torrent_id()) -> true.
register_directory(TorrentID) ->
    gproc:add_local_name({etorrent, TorrentID, directory}).

%% @end
%% Register the current process as the file server for the
%% file-path in the directory. A process being registered
%% as a file server does not imply that it can perform IO
%% operations on the behalf of IO clients.
%% @doc
-spec register_file_server(torrent_id(), file_path()) -> true.
register_file_server(TorrentID, Path) ->
    gproc:add_local_name({etorrent, TorrentID, Path, file}).


%% @doc
%% Lookup the process id of the directory server responsible
%% for the given torrent. If there is no such server registered
%% this function will crash.
%% @end
-spec lookup_directory(torrent_id()) -> pid().
lookup_directory(TorrentID) ->
    gproc:lookup_local_name({etorrent, TorrentID, directory}).

%% @doc
%% Wait for the directory server for this torrent to appear
%% in the process registry.
%% @end
-spec await_directory(torrent_id()) -> {ok, pid()}.
await_directory(TorrentID) ->
    Name = {etorrent, TorrentID, directory},
    {DirPid, undefined} = gproc:await({n, l, Name}, ?AWAIT_TIMEOUT),
    {ok, DirPid}.

%% @doc
%% Lookup the process id of the file server responsible for
%% performing IO operations on this path. If there is no such
%% server registered this function will crash.
%% @end
-spec lookup_file_server(torrent_id(), file_path()) -> pid().
lookup_file_server(TorrentID, Path) ->
    gproc:lookup_local_name({etorrent, TorrentID, Path, file}).

%% @doc
%% Register the current process as a file server as being
%% in a state where it is ready to perform IO operations
%% on behalf of clients.
%% @end
-spec register_open_file(torrent_id(), file_path()) -> true.
register_open_file(TorrentID, Path) ->
    gproc:add_local_name({etorrent, TorrentID, Path, file, open}).

%% @doc
%% Register that the current process is a file server that
%% is not in a state where it can (successfully) perform
%% IO operations on behalf of clients.
%% @end
-spec unregister_open_file(torrent_id(), file_path()) -> true.
unregister_open_file(TorrentID, Path) ->
    gproc:unreg({n, l, {etorrent, TorrentID, Path, file, open}}).


%% @doc
%% Wait for the file server responsible for the given file to start
%% and return the process id of the file server.
%% @end
-spec await_file_server(torrent_id(), file_path()) -> {ok, pid()}.
await_file_server(TorrentID, Path) ->
    Name = {etorrent, TorrentID, Path, file},
    {FilePid, undefined} = gproc:await({n, l, Name}, ?AWAIT_TIMEOUT),
    {ok, FilePid}.

%% @doc
%% Wait for the file server responsible for the given file
%% to enter a state where it is able to perform IO operations.
%% @end
-spec await_open_file(torrent_id(), file_path()) -> {ok, pid()}.
await_open_file(TorrentID, Path) ->
    Name = {etorrent, TorrentID, Path, file, open},
    {FilePid, undefined} = gproc:await({n, l, Name}, ?AWAIT_TIMEOUT),
    {ok, FilePid}.

%% @doc
%% Fetch the offsets and length of the file blocks of the piece
%% from this directory server.
%% @end
-spec get_positions(pid(), piece_index()) -> {'ok', list(block_pos())}.
get_positions(DirPid, Piece) ->
    gen_server:call(DirPid, {get_positions, Piece}).

%% @doc
%% Notify the directory server that the current process intends
%% to perform an IO-operation on a file. This is so that the directory
%% can notify the file server to open it's file if needed.
%% @end
-spec schedule_io_operation(torrent_id(), file_path()) -> ok.
schedule_io_operation(Directory, RelPath) ->
    {ok, DirPid} = await_directory(Directory),
    gen_server:cast(DirPid, {schedule_operation, RelPath}).


init([TorrentID, Torrent]) ->
    % Let the user define a limit on the amount of files
    % that will be open at the same time
    MaxFiles = etorrent_config:max_files(),
    true = register_directory(TorrentID),
    PieceMap  = make_piece_map(Torrent),
    InitState = #state{
        torrent=TorrentID,
        pieces=PieceMap,
        files_open=[],
        files_max=MaxFiles},
    {ok, InitState}.

%%
%% Add a no-op implementation of the the file-server protocol.
%% This enables the directory server to unlock io-clients waiting
%% for a file server to enter the open state when the file server
%% crashed before it could enter the open state.
%%
handle_call({read, _, _}, _, State) ->
    {reply, {error, eagain}, State};
handle_call({write, _, _}, _, State) ->
    {reply, {error, eagain}, State};

handle_call({get_positions, Piece}, _, State) ->
    #state{pieces=PieceMap} = State,
    Positions = array:get(Piece, PieceMap),
    {reply, {ok, Positions}, State}.

handle_cast({schedule_operation, RelPath}, State) ->
    #state{
        torrent=TorrentID,
        files_open=FilesOpen,
        files_max=MaxFiles} = State,

    FileInfo  = lists:keyfind(RelPath, #io_file.rel_path, FilesOpen),
    AtLimit   = length(FilesOpen) >= MaxFiles,

    %% If the file that the client intends to operate on is not open and
    %% the quota on the number of open files has been met, tell the least
    %% recently used file complete all outstanding requests
    OpenAfterClose = case {FileInfo, AtLimit} of
        {_, false} ->
            FilesOpen;
        {false, true} ->
            ByAccess = lists:keysort(#io_file.accessed, FilesOpen),
            [LeastRecent|FilesToKeep] = lists:reverse(ByAccess),
            #io_file{
                process=ClosePid,
                monitor=CloseMon} = LeastRecent,
            ok = etorrent_io_file:close(ClosePid),
            _  = erlang:demonitor(CloseMon, [flush]),
            FilesToKeep;
        {_, true} ->
            FilesOpen
    end,

    %% If the file that the client intends to operate on is not open;
    %% Always tell the file server to open the file as soon as possbile.
    %% If the file is open, just update the access time.
    WithNewFile = case FileInfo of
        false ->
            {ok, NewPid} = await_file_server(TorrentID, RelPath),
            NewMon = erlang:monitor(process, NewPid),
            ok = etorrent_io_file:open(NewPid),
            NewFile = #io_file{
                rel_path=RelPath,
                process=NewPid,
                monitor=NewMon,
                accessed=now()},
            [NewFile|OpenAfterClose];
        _ ->
            UpdatedFile = FileInfo#io_file{accessed=now()},
            lists:keyreplace(RelPath, #io_file.rel_path, OpenAfterClose, UpdatedFile)
    end,
    NewState = State#state{files_open=WithNewFile},
    {noreply, NewState}.

handle_info({'DOWN', FileMon, _, _, _}, State) ->
    #state{
        torrent=TorrentID,
        files_open=FilesOpen} = State,
    ClosedFile = lists:keyfind(FileMon, #io_file.monitor, FilesOpen),
    #io_file{rel_path=RelPath} = ClosedFile,
    %% Unlock clients that called schedule_io_operation before this
    %% file server crashed and the file server received the open-notification.
    true = register_open_file(TorrentID, RelPath),
    true = unregister_open_file(TorrentID, RelPath),
    NewFilesOpen = lists:keydelete(FileMon, #io_file.monitor, FilesOpen),
    NewState = State#state{files_open=NewFilesOpen},
    {noreply, NewState}.

terminate(_, _) ->
    not_implemented.

code_change(_, _, _) ->
    not_implemented.

%%
%%
make_piece_map(Torrent) ->
    PieceLength = etorrent_metainfo:get_piece_length(Torrent),
    FileLengths = file_path_len(Torrent),
    MapEntries  = make_piece_map_(PieceLength, FileLengths),
    lists:foldl(fun({Path, Piece, Offset, Length}, Acc) ->
        Prev = array:get(Piece, Acc),
        With = Prev ++ [{Path, Offset, Length}],
        array:set(Piece, With, Acc)
    end, array:new({default, []}), MapEntries).

%%
%% Calculate the positions where pieces start and continue in the
%% the list of files included in a torrent file.
%%
%% The piece offset is non-zero if the piece spans two files. The piece
%% index for the second entry should be the amount of bytes included
%% (length in output) in the first entry.
%%
make_piece_map_(PieceLength, FileLengths) ->
    make_piece_map_(PieceLength, 0, 0, 0, FileLengths).

make_piece_map_(_, _, _, _, []) ->
    [];
make_piece_map_(PieceLen, PieceOffs, Piece, FileOffs, [{Path, Len}|T]=L) ->
    BytesToEnd = PieceLen - PieceOffs,
    case FileOffs + BytesToEnd of
        %% This piece ends at the end of this file
        NextOffs when NextOffs == Len ->
            Entry = {Path, Piece, FileOffs, BytesToEnd},
            [Entry|make_piece_map_(PieceLen, 0, Piece+1, 0, T)];
        %% This piece ends in the middle of this file
        NextOffset when NextOffset < Len ->
            NewFileOffs  = FileOffs + BytesToEnd,
            Entry = {Path, Piece, FileOffs, BytesToEnd},
            [Entry|make_piece_map_(PieceLen, 0, Piece+1, NewFileOffs, L)];
        %% This piece ends in the next file
        NextOffset when NextOffset > Len ->
            InThisFile = Len - FileOffs,
            NewPieceOffs = PieceOffs + InThisFile,
            Entry = {Path, Piece, FileOffs, InThisFile},
            [Entry|make_piece_map_(PieceLen, NewPieceOffs, Piece, 0, T)]
    end.

%%
%% Calculate the positions where a chunk starts and continues in the
%% file blocks that make up a piece. 
%% Piece offset will only be non-zero at the initial call. After the block
%% has crossed a file boundry the offset of the block in the piece is zeroed
%% and the amount of bytes included in the first file block is subtracted 
%% from the chunk length.
%%
chunk_positions(_, _, []) ->
    [];

chunk_positions(ChunkOffs, ChunkLen, [{Path, FileOffs, BlockLen}|T]) ->
    LastBlockByte = FileOffs + BlockLen,
    EffectiveOffs = FileOffs + ChunkOffs,
    LastChunkByte = EffectiveOffs + ChunkLen,
    if  %% The first byte of the chunk is in the next file
        ChunkOffs > BlockLen ->
            NewChunkOffs = ChunkOffs - BlockLen,
            chunk_positions(NewChunkOffs, ChunkLen, T);
        %% The chunk ends at the end of this file block
        LastChunkByte =< LastBlockByte -> % false
            [{Path, EffectiveOffs, ChunkLen}];
        %% This chunk ends in the next file block
        LastChunkByte > LastBlockByte ->
            OutBlockLen = LastBlockByte - EffectiveOffs,
            NewChunkLen = ChunkLen - OutBlockLen,
            Entry = {Path, EffectiveOffs, OutBlockLen},
            [Entry|chunk_positions(0, NewChunkLen, T)]
    end.
            


-ifdef(TEST).
piece_map_0_test() ->
    Size  = 2,
    Files = [{a, 4}],
    Map   = [{a, 0, 0, 2}, {a, 1, 2, 2}],
    ?assertEqual(Map, make_piece_map_(Size, Files)).

piece_map_1_test() ->
    Size  = 2,
    Files = [{a, 2}, {b, 2}],
    Map   = [{a, 0, 0, 2}, {b, 1, 0, 2}],
    ?assertEqual(Map, make_piece_map_(Size, Files)).

piece_map_2_test() ->
    Size  = 2,
    Files = [{a, 3}, {b, 1}],
    Map   = [{a, 0, 0, 2}, {a, 1, 2, 1}, {b, 1, 0, 1}],
    ?assertEqual(Map, make_piece_map_(Size, Files)).

chunk_pos_0_test() ->
    Offs = 1,
    Len  = 3,
    Map  = [{a, 0, 4}],
    Pos  = [{a, 1, 3}],
    ?assertEqual(Pos, chunk_positions(Offs, Len, Map)). 

chunk_pos_1_test() ->
    Offs = 2,
    Len  = 4,
    Map  = [{a, 1, 8}],
    Pos  = [{a, 3, 4}],
    ?assertEqual(Pos, chunk_positions(Offs, Len, Map)). 

chunk_pos_2_test() ->
    Offs = 3,
    Len  = 9,
    Map  = [{a, 2, 4}, {b, 0, 10}],
    Pos  = [{a, 5, 1}, {b, 0, 8}],
    ?assertEqual(Pos, chunk_positions(Offs, Len, Map)). 

chunk_post_3_test() ->
    Offs = 8,
    Len  = 5,
    Map  = [{a, 0, 3}, {b, 0, 13}],
    Pos  = [{b, 5, 5}],
    ?assertEqual(Pos, chunk_positions(Offs, Len, Map)). 
    
-endif.
