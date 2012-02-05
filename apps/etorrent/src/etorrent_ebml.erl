-module(etorrent_ebml).

%% API for retriving information
-behaviour(gen_server).


-export([find_subtitles/2]).

-export([init/1,
         handle_call/3,
         terminate/2,
         code_change/3]).

-record(state, {
    server,
    torrent_id,
    file_id,
    size
}).


start_link(Tid, Fid) ->
    gen_server:start_link(?MODULE, [Tid, Fid], []).


find_subtitles(Tid, Fid) ->
    application:start(ebml),
    {ok, Fd} = start_link(Tid, Fid),
    ebml_file:find_subtitles(Fd).


wait(Tid, Fid, Offset, Length) ->
    Wanted = etorrent_io:get_mask(Tid, Fid, Offset, Length),
    CtlPid = etorrent_torrent_ctl:lookup_server(Tid),
    {ok, Valid} = etorrent_torrent_ctl:valid_pieces(CtlPid),
    io:write([Offset, Length]),
    Diff = etorrent_pieceset:difference(Wanted, Valid),
    case etorrent_pieceset:size(Diff) of
        %% Already downloaded
        0 -> ok;
        _ -> 
            %% Set wish
            Pieces = etorrent_pieceset:to_list(Diff),
            io:format("Wish pieces ~w", [Pieces]),
            etorrent_torrent_ctl:wish_piece(Tid, Pieces),
            {ok, _Status, Ref} = etorrent_torrent_ctl:subscribe(Tid, piece, Pieces),
            %% Waiting...
            receive
                {completed,Ref,piece,Pieces} -> ok
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

    Size = etorrent_io:file_size(Tid, Fid),

    {ok, #state{ server=FileServer, torrent_id=Tid, file_id=Fid, size=Size }}.


handle_call({read, Offset, Length}, _, State) ->
    #state{server=FileServer, torrent_id=Tid, file_id=Fid} = State,
    wait(Tid, Fid, Offset, Length),
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
