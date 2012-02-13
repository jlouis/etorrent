-module(etorrent_ebml).

%% API for retriving information
-behaviour(gen_server).
-compile([export_all]).


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
    file_start,
    piece_size,
    queries = [],
    chunk_server :: pid()
}).

-record(chunk_query, {
    id :: reference(),
    client :: [{pid(), reference()}],
    offset :: non_neg_integer(),
    length :: non_neg_integer()
}).


open(Tid, Fid) ->
    application:start(ebml),
    {ok, Fd} = gen_server:start_link(?MODULE, [Tid, Fid], [{timeout, infinity}, {debug,[trace]}]),
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


wait(ChunkSrv, Tid, Fid, Offset, Length, FileStart, PSize) ->
    Wanted = etorrent_io:get_mask(Tid, Fid, Offset, Length),
    CtlPid = etorrent_torrent_ctl:lookup_server(Tid),
    {ok, Valid} = etorrent_torrent_ctl:valid_pieces(CtlPid),
    Diff = etorrent_pieceset:difference(Wanted, Valid),
    case etorrent_pieceset:size(Diff) of
        %% Already downloaded
        0 -> ok;
        %% Working with chunks
        _PieceCount -> 
            %% Offset from beginning of the torrent
            AbsOffset = FileStart + Offset,
            Chunks = range_to_chunks(AbsOffset, Length, PSize),

            Status = etorrent_reordered:monitor_chunks(ChunkSrv, Chunks),
            case Status of
                completed -> ok;
                {subscribed, Ref} -> 
                    io:write({'-', Offset, Length}),
                    {subscribed, Ref}
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

    Size  = etorrent_io:file_size(Tid, Fid),
    Pos   = etorrent_io:file_position(Tid, Fid),
    PSize = etorrent_io:piece_size(Tid),

    CtlPid = etorrent_torrent_ctl:lookup_server(Tid),
    etorrent_torrent_ctl:switch_mode(CtlPid, reordered),

    %% If chunk_server will fail, this process will fail too.
    ChunkSrv = etorrent_reordered:await_server(Tid),
    erlang:monitor(process, ChunkSrv),
    erlang:monitor(process, FileServer),

    {ok, #state{ server=FileServer, torrent_id=Tid, file_id=Fid, 
                 size=Size, file_start=Pos, piece_size=PSize,
                 chunk_server=ChunkSrv }}.


handle_call({read, Offset, Length}, {Pid, _Ref}=Client, State) ->
    #state{server=FileServer, torrent_id=Tid, file_id=Fid, 
            file_start=FileStart, piece_size=PSize,
            queries=Queries, chunk_server=ChunkSrv} = State,

    case wait(ChunkSrv, Tid, Fid, Offset, Length, FileStart, PSize) of
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


handle_info({completed, Ref}, State) ->

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
    {noreply, State#state{queries=Rest}}.
    

terminate(_, _) ->
    ok.


%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @doc Split a monolitic range to a list of pieces.
%% @param Start      Offset from the beginning of the torrent.
%% @param Length     of the unsplited range.
%% @param PSize      Size of the piece.
%% @return [{PieceId, PieceStartOffset, ChunkLength}
range_to_chunks(Start, Length, PSize) ->
    %% Offset from beginning of the piece
    PieceOffset  = Start rem PSize,
    FirstPieceId = Start div PSize,
    ChunkLength  = min(PSize - PieceOffset, Length),
    Left = Length - ChunkLength,
    Chunk = {FirstPieceId, PieceOffset, ChunkLength},
    to_chunks_(FirstPieceId + 1, Left, PSize, [Chunk]).


to_chunks_(PieceId, Left, PSize, Acc) when Left =< 0 ->
    lists:reverse(Acc);

to_chunks_(PieceId, Left, PSize, Acc) when Left >= PSize ->
    Chunk = {PieceId, 0, PSize},
    to_chunks_(PieceId + 1, Left - PSize, PSize, [Chunk|Acc]);

to_chunks_(PieceId, Left, PSize, Acc) ->
    Chunk = {PieceId, 0, Left},
    lists:reverse([Chunk|Acc]).
    

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

range_to_chunks_test_() ->
    % 012|345|678  Offset from the beginning of the torrent
    % -----------
    % xoo|
    [ ?_assertEqual(range_to_chunks(0, 1, 3), [{0, 0, 1}])
    % ooo|xoo
    , ?_assertEqual(range_to_chunks(3, 1, 3), [{1, 0, 1}])
    % oox|xoo
    , ?_assertEqual(range_to_chunks(2, 2, 3), [{0, 2, 1}, {1, 0, 1}])
    % xxx|xxx
    , ?_assertEqual(range_to_chunks(0, 6, 3), [{0, 0, 3}, {1, 0, 3}])
    % xxx|xxx|x
    , ?_assertEqual(range_to_chunks(0, 7, 3), [{0, 0, 3}, {1, 0, 3}, {2, 0, 1}])
    ].

-endif.
