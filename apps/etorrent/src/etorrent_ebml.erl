-module(etorrent_ebml).

%% API for retriving information
-behaviour(gen_server).


-export([tracks/2]).

-export([init/1,
         handle_call/3,
         terminate/2,
         code_change/3]).

-record(state, {
    server,
    torrent_id,
    file_id,
    size,
    position,
    piece_size
}).


open(Tid, Fid) ->
    application:start(ebml),
    {ok, Fd} = gen_server:start_link(?MODULE, [Tid, Fid], []),
    ebml_proxy:open(Fd).


tracks(Tid, Fid) ->
    {ok, Fd} = open(Tid, Fid),
    ebml_file:track_list(Fd).


find_subtitles(Tid, Fid) ->
    {ok, Fd} = open(Tid, Fid),
    [ebml_file:extract_subtitle_binary(Fd, X) 
        || X <- ebml_file:find_subtitles(Fd)].


wait(Tid, Fid, Offset, Length, Pos, PSize) ->
    Wanted = etorrent_io:get_mask(Tid, Fid, Offset, Length),
    CtlPid = etorrent_torrent_ctl:lookup_server(Tid),
    {ok, Valid} = etorrent_torrent_ctl:valid_pieces(CtlPid),
    io:write([Offset, Length]),
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
            ok = etorrent_progress:wish_chunk(Tid, PieceID, PieceOffset, Length),
            Status = etorrent_progress:monitor_chunk(Tid, PieceID, PieceOffset, Length),
            case Status of
                completed -> ok;
                {subscribed, Ref} ->
                    %% Waiting...
                    receive
                        {chunk_completed, Ref} -> ok
                    end
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
                {subscribed, Ref} ->
                    %% Waiting...
                    receive
                        {completed,Ref} -> ok
                    end
            end
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

    {ok, #state{ server=FileServer, torrent_id=Tid, file_id=Fid, 
                 size=Size, position=Pos, piece_size=PSize }}.


handle_call({read, Offset, Length}, _, State) ->
    #state{server=FileServer, torrent_id=Tid, file_id=Fid, 
            position=Pos, piece_size=PSize} = State,
    wait(Tid, Fid, Offset, Length, Pos, PSize),
    %% @TODO rewrite
    case etorrent_io_file:read(FileServer, Offset, Length) of
    {ok, Chunk} ->
        {reply, {ok, Chunk}, State};

    {error,eagain} ->
        etorrent_io_file:open(FileServer),
        {ok, Chunk} = etorrent_io_file:read(FileServer, Offset, Length),
        {reply, {ok, Chunk}, State}
    end;

handle_call(size, _, State) ->
    {reply, {ok, State#state.size}, State}.


terminate(_, _) ->
    ok.


%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
