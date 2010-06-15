%%%-------------------------------------------------------------------
%%% File    : file_system.erl
%%% Author  : User Jlouis <jesper.louis.andersen@gmail.com>
%%% License : See COPYING
%%% Description : Implements access to the file system through
%%%               file_process processes.
%%%
%%% Created : 19 Jun 2007 by User Jlouis <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_fs).

-include("etorrent_piece.hrl").
-include("etorrent_mnesia_table.hrl").
-include("types.hrl").
-include("log.hrl").

-behaviour(gen_server).

%% API
-export([start_link/2,
         read_piece/2, read_chunk/4, write_chunk/2, check_piece/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, { torrent_id = none, %% id of torrent we are serving
                 file_pool = none,
                 supervisor = none,
                 file_process_dict = none}).

%%====================================================================

%% @doc Spawn and link a new file_system process
%% @end
-spec start_link(integer(), pid()) ->
    ignore | {ok, pid()} | {error, any()}.
start_link(IDHandle, SPid) ->
    gen_server:start_link(?MODULE, [IDHandle, SPid], []).

%% @doc Read a single chunk
%% @end
-spec read_chunk(pid(), integer(), integer(), integer()) ->
    {ok, binary()}.
read_chunk(Pid, Pn, Offset, Len) ->
    gen_server:call(Pid, {read_chunk, Pn, Offset, Len}).

%% @doc Ask file_system process Pid to retrieve Piece N
%% @end
-spec read_piece(pid(), integer()) -> {ok, binary()}.
read_piece(Pid, Pn) when is_integer(Pn) ->
    gen_server:call(Pid, {read_piece, Pn}).

%% @doc Search the mnesia tables for the Piece with Index and
%%   write it back to disk.
%% @end
-spec check_piece(pid(), integer()) -> ok.
check_piece(Pid, Index) ->
    gen_server:cast(Pid, {check_piece, Index}).

%% @doc writes a chunk, {Index, Data, Ops} back to disk. Pid is the FS Pid
%%   which should carry out the writing operation.
%% @end
-spec write_chunk(pid(), {integer(), binary(), [operation()]}) -> ok.
write_chunk(Pid, {Index, Data, Ops}) ->
    gen_server:cast(Pid, {write_chunk, {Index, Data, Ops}}).

%%====================================================================
init([IDHandle, SPid]) when is_integer(IDHandle) ->
    process_flag(trap_exit, true),
    {ok, #state{file_process_dict = dict:new(),
                file_pool = none,
                supervisor = SPid,
                torrent_id = IDHandle}}.

handle_call(Msg, _From, S) when S#state.file_pool =:= none ->
    FSPool = etorrent_t_sup:get_pid(S#state.supervisor, fs_pool),
    handle_call(Msg, _From, S#state { file_pool = FSPool });
handle_call({read_piece, PieceNum}, _From, S) ->
    [#piece { files = Operations}] =
        etorrent_piece_mgr:select(S#state.torrent_id, PieceNum),
    {Data, NS} = read_pieces_and_assemble(Operations, S),
    {reply, {ok, Data}, NS};
handle_call({read_chunk, Pn, Offset, Len}, _From, S) ->
    [#piece { files = Operations}] =
        etorrent_piece_mgr:select(S#state.torrent_id, Pn),
    {Reply, NS} = read_chunk_and_assemble(Operations, Offset, Len, S),
    {reply, Reply, NS};
handle_call(Msg, From, S) ->
    ?log([unknown_call, Msg, From, S]),
    {noreply, S}.

handle_cast(Msg, S) when S#state.file_pool =:= none ->
    FSPool = etorrent_t_sup:get_pid(S#state.supervisor, fs_pool),
    handle_cast(Msg, S#state { file_pool = FSPool });
handle_cast({write_chunk, {Index, Data, Ops}}, S) ->
    case etorrent_piece_mgr:select(S#state.torrent_id, Index) of
        [P] when P#piece.state =:= fetched ->
            {noreply, S};
        [_] ->
            NS = fs_write(Data, Ops, S),
            {noreply, NS}
    end;
handle_cast({check_piece, Index}, S) ->
    [#piece { hash = Hash, files = Operations}] =
        etorrent_piece_mgr:select(S#state.torrent_id, Index),
    {Data, NS} = read_pieces_and_assemble(Operations, S),
    DataSize = byte_size(Data),
    case Hash == crypto:sha(Data) of
        true ->
            ok = etorrent_torrent:statechange(
                   S#state.torrent_id,
                   [{subtract_left, DataSize},
                   {add_downloaded, DataSize}]),
            ok = etorrent_piece_mgr:statechange(
                   S#state.torrent_id,
                   Index,
                   fetched),
            etorrent_peer:broadcast_peers(S#state.torrent_id,
                    fun(P) -> 
                          etorrent_peer_control:have(P, Index)
                    end),
            {noreply, NS};
        false ->
            ok =
                etorrent_piece_mgr:statechange(S#state.torrent_id,
                                               Index,
                                               not_fetched),
            {noreply, NS}
    end;
handle_cast(Msg, State) ->
    ?log([unknown_msg, Msg]),
    {noreply, State}.

handle_info({'DOWN', _R, process, Pid, _Reason}, S) ->
    Nd = remove_file_process(Pid, S#state.file_process_dict),
    {noreply, S#state { file_process_dict = Nd }};
handle_info(Info, State) ->
    ?log([unknown_info_msg, Info]),
    {noreply, State}.

terminate(_Reason, S) ->
    ok = stop_all_fs_processes(S#state.file_process_dict),
    ok = etorrent_path_map:delete(S#state.torrent_id),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =======================================================================
create_file_process(Id, S) ->
    {ok, Pid} = etorrent_fs_pool_sup:add_file_process(S#state.file_pool,
                                                      S#state.torrent_id, Id),
    erlang:monitor(process, Pid),
    NewDict = dict:store(Id, Pid, S#state.file_process_dict),
    {ok, Pid, S#state{ file_process_dict = NewDict }}.

read_chunk_and_assemble(Ops, Offset, Len, S) ->
    read_chunk_and_assemble(Ops, <<>>, Offset, Len, S).

read_chunk_and_assemble(_Ops, Done, _Offset, 0, S) -> {{ok, Done}, S};
read_chunk_and_assemble([{_Id, _OS, Sz} | Rest], Done, Offset, L, S)
        when Offset >= Sz ->
    read_chunk_and_assemble(Rest, Done, Offset-Sz, L, S);
read_chunk_and_assemble([{Id, OS, Sz} | Rest], Done, Offset, L, S)
        when (Offset+L) > Sz ->
    {value, Data, NS} = read(Id, OS+Offset, Sz-Offset, S),
    read_chunk_and_assemble(Rest, <<Done/binary, Data/binary>>,
                            0,
                            L - (Sz - Offset), NS);
read_chunk_and_assemble([{Id, OS, _Sz} | _Rest], Done, Offset, L, S) ->
    {value, Data, NS} = read(Id, OS+Offset, L, S),
    {{ok, <<Done/binary, Data/binary>>}, NS}.

read(Id, Offset, Sz, S) ->
    case dict:find(Id, S#state.file_process_dict) of
        {ok, Pid} ->
            try
                {ok, Data} = etorrent_fs_process:read(Pid, Offset, Sz),
                {value, Data, S}
            catch
                exit:{noproc, _} ->
                    D = remove_file_process(Pid, S#state.file_process_dict),
                    read(Id, Offset, Sz, S#state{file_process_dict = D})
            end;
        error ->
            {ok, _Pid, NS} = create_file_process(Id, S),
            read(Id, Offset, Sz, NS)
    end.

read_pieces_and_assemble(Ops, S) ->
    read_pieces_and_assemble(Ops, <<>>, S).

read_pieces_and_assemble([], Done, S) -> {Done, S};
read_pieces_and_assemble([{Id, Offset, Size} | Rest], SoFar, S) ->
    {value, Data, NS} = read(Id, Offset, Size, S),
    read_pieces_and_assemble(Rest, <<SoFar/binary, Data/binary>>, NS).

%% @doc Write data defined by Operations. Returns new State
%%   maintaining the file_process_dict.
%% @end
-spec fs_write(binary(), [operation()], #state{}) -> #state{}.
fs_write(<<>>, [], S) -> S;
fs_write(Data, [{Id, Offset, Size} | Rest], S) ->
    <<Chunk:Size/binary, Remaining/binary>> = Data,
    case dict:find(Id, S#state.file_process_dict) of
        {ok, Pid} ->
            try
                ok = etorrent_fs_process:write(Pid, Chunk, Offset, Size),
                fs_write(Remaining, Rest, S)
            catch
                exit:{noproc, _} ->
                    D = remove_file_process(Pid, S#state.file_process_dict),
                    fs_write(Data, [{Id, Offset, Size} | Rest],
                             S#state {file_process_dict = D})
            end;
        error ->
            {ok, _Pid, NS} = create_file_process(Id, S),
            fs_write(Data, [{Id, Offset, Size} | Rest], NS)
    end.

remove_file_process(Pid, Dict) ->
    case dict:fetch_keys(dict:filter(fun (_K, V) -> V =:= Pid end, Dict)) of
        [Key] ->
            dict:erase(Key, Dict);
        [] ->
            Dict
    end.

stop_all_fs_processes(Dict) ->
    lists:foreach(fun({_, Pid}) -> etorrent_fs_process:stop(Pid) end,
                  dict:to_list(Dict)),
    ok.
