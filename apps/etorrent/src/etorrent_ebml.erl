-module(etorrent_ebml).

%% API for retriving information
-behaviour(gen_server).


-export([tracks/2,
         track/3,
         read_subtitles/3]).

-export([init/1,
         handle_call/3,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {
    server,
    torrent_id,
    file_id,
    size,
    position,
    piece_size,
    queries = [],
    chunk_server :: pid()
}).

-record(chunk_query, {
    id :: reference(),
    client :: {pid(), reference()},
    offset :: non_neg_integer(),
    length :: non_neg_integer()
}).


open(Tid, Fid) ->
    application:start(ebml),
    {ok, Fd} = gen_server:start_link(?MODULE, [Tid, Fid], []),
    ebml_proxy:open(Fd).


tracks(Tid, Fid) ->
    {ok, Fd} = open(Tid, Fid),
    ebml_file:track_list(Fd).


track(Tid, Fid, TrackId) ->
    {ok, Fd} = open(Tid, Fid),
    ebml_file:track(Fd, TrackId).


read_subtitles(Tid, Fid, TrackId) ->
    {ok, Fd} = open(Tid, Fid),
    ebml_file:read_subtitles(Fd, TrackId).


find_subtitles(Tid, Fid) ->
    {ok, Fd} = open(Tid, Fid),
    [ebml_file:extract_subtitle_binary(Fd, X) 
        || X <- ebml_file:find_subtitles(Fd)].

wait(ChunkSrv, Tid, Fid, Offset, Length, Pos, PSize) ->
    Wanted = etorrent_io:get_mask(Tid, Fid, Offset, Length),
    CtlPid = etorrent_torrent_ctl:lookup_server(Tid),
    {ok, Valid} = etorrent_torrent_ctl:valid_pieces(CtlPid),
    Diff = etorrent_pieceset:difference(Wanted, Valid),
    case etorrent_pieceset:size(Diff) of
        %% Already downloaded
        0 -> ok;
        %% Working with chunks
        1 -> 
            [PieceID] = Pieces = etorrent_pieceset:to_list(Diff),
            %% Add a permanent wish
            etorrent_torrent_ctl:wish_piece(Tid, Pieces, true),
            %% Offset from beginning of the torrent
            AbsOffset = Pos + Offset,
            %% Offset from beginning of the piece
            PieceOffset = AbsOffset rem PSize,
            ok = etorrent_progress:wish_chunk(ChunkSrv, PieceID, 
                PieceOffset, Length),
            Status = etorrent_progress:monitor_chunk(ChunkSrv, PieceID, 
                PieceOffset, Length),
            case Status of
                completed -> ok;
                {subscribed, Ref} -> 
                    io:write({'-', Offset, Length}),
                    {subscribed, Ref}
            end;

        %% Many pieces
        _ -> 
            %% Set wish
            Pieces = etorrent_pieceset:to_list(Diff),
            io:format("Wish pieces ~w", [Pieces]),
            %% Add a permanent wish
            etorrent_torrent_ctl:wish_piece(Tid, Pieces, true),
            Status = etorrent_torrent_ctl:subscribe(Tid, piece, Pieces),
            case Status of
                completed -> ok;
                {subscribed, Ref} -> {subscribed, Ref}
            end
    end.


read(FileServer, Offset, Length) ->
    %% @TODO rewrite
    case etorrent_io_file:read(FileServer, Offset, Length) of
    {ok, Chunk} ->
        Chunk;

    {error,eagain} ->
        etorrent_io_file:open(FileServer),
        {ok, Chunk} = etorrent_io_file:read(FileServer, Offset, Length),
        Chunk
    end.


init([Tid, Fid]) ->
    RelName = etorrent_io:file_name(Tid, Fid),
    FileServer = etorrent_io:lookup_file_server(Tid, RelName),

    Fn = fun(Offset, Length) ->
        %% Find server by filename
        FileServerI = etorrent_io:lookup_file_server(Tid, RelName),
        etorrent_io_file:read(FileServerI, Offset, Length)
        end,

    Size  = etorrent_io:file_size(Tid, Fid),
    Pos   = etorrent_io:file_position(Tid, Fid),
    PSize = etorrent_io:piece_size(Tid),

    %% If chunk_server will fail, this process will fail too.
    ChunkSrv = etorrent_progress:lookup_server(Tid),
    erlang:monitor(process, ChunkSrv),

    {ok, #state{ server=FileServer, torrent_id=Tid, file_id=Fid, 
                 size=Size, position=Pos, piece_size=PSize,
                 chunk_server=ChunkSrv }}.


handle_call({read, Offset, Length}, Client, State) ->
    #state{server=FileServer, torrent_id=Tid, file_id=Fid, 
            position=Pos, piece_size=PSize,
            queries=Queries, chunk_server=ChunkSrv} = State,

    case wait(ChunkSrv, Tid, Fid, Offset, Length, Pos, PSize) of
    ok ->
        Chunk = read(FileServer, Offset, Length),
        {reply, {ok, Chunk}, State};

    {subscribed, Ref} ->
        Query = #chunk_query {
            id     = Ref,
            client = Client,
            offset = Offset,
            length = Length
        },
        {noreply, State#state{queries=[Query|Queries]}}
    end;

handle_call(size, _, State) ->
    {reply, {ok, State#state.size}, State}.


handle_info({Tag, Ref}, State) 
    when Tag =:= completed; % piece
         Tag =:= chunk_completed ->

    #state{server=FileServer, 
            queries=Queries} = State,

    {value, Query, Rest} = lists:keytake(Ref, #chunk_query.id, Queries),

    #chunk_query {
        client = Client,
        offset = Offset,
        length = Length
    } = Query,

    io:write({'+', Offset, Length}),
    
    Chunk = read(FileServer, Offset, Length),
    Reply = {ok, Chunk},
    gen_server:reply(Client, Reply),
    {noreply, {ok, State#state.size}, State#state{queries=Rest}}.
    

terminate(_, _) ->
    ok.


%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
