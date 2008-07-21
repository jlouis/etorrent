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

-behaviour(gen_server).

%% API
-export([start_link/2,
	 stop/1, read_piece/2, size_of_ops/1,
	 write_chunk/2, check_piece/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, { torrent_id = none, %% id of torrent we are serving
		 file_pool = none,
		 supervisor = none,
		 file_process_dict = none}).

%%====================================================================
%% API
%%====================================================================

%%--------------------------------------------------------------------
%% Function: size_of_ops(operation_list) -> integer()
%% Description: Return the file size of the given operations
%%--------------------------------------------------------------------
size_of_ops(Ops) ->
    lists:sum([Size || {_Path, _Offset, Size} <- Ops]).

%%--------------------------------------------------------------------
%% Function: start_link/0
%% Description: Spawn and link a new file_system process
%%--------------------------------------------------------------------
start_link(IDHandle, SPid) ->
    gen_server:start_link(?MODULE, [IDHandle, SPid], []).

%%--------------------------------------------------------------------
%% Function: stop(Pid) -> ok
%% Description: Stop the file_system process identified by Pid
%%--------------------------------------------------------------------
stop(Pid) ->
    gen_server:cast(Pid, stop).

%%--------------------------------------------------------------------
%% Function: read_piece(Pid, N) -> {ok, Binary}
%% Description: Ask file_system process Pid to retrieve Piece N
%%--------------------------------------------------------------------
read_piece(Pid, Pn) when is_integer(Pn) ->
    gen_server:call(Pid, {read_piece, Pn}).

%%--------------------------------------------------------------------
%% Function: check_piece(Pid, PeerGroupPid, Index) -> ok | wrong_hash
%% Description: Search the mnesia tables for the Piece with Index and
%%   write it back to disk.
%%--------------------------------------------------------------------
check_piece(Pid, PeerGroupPid, Index) ->
    gen_server:cast(Pid, {check_piece, PeerGroupPid, Index}).

%%% TODO: The PeerGroupPid could be obtained by the process itself.
write_chunk(Pid, {Index, Data, Ops}) ->
    gen_server:cast(Pid, {write_chunk, {Index, Data, Ops}}).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([IDHandle, SPid]) when is_integer(IDHandle) ->
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
    {ok, Data, NS} = read_pieces_and_assemble(Operations, [], S),
    {reply, {ok, Data}, NS}.

handle_cast(Msg, S) when S#state.file_pool =:= none ->
    FSPool = etorrent_t_sup:get_pid(S#state.supervisor, fs_pool),
    handle_cast(Msg, S#state { file_pool = FSPool });
handle_cast({write_chunk, {Index, Data, Ops}}, S) ->
    case etorrent_piece_mgr:select(S#state.torrent_id, Index) of
	[P] when P#piece.state =:= fetched ->
	    {noreply, S};
	[_] ->
	    {ok, NS} = fs_write(Data, Ops, S),
	    {noreply, NS}
    end;
handle_cast({check_piece, PeerGroupPid, Index}, S) ->
    [#piece { hash = Hash, files = Operations}] =
	etorrent_piece_mgr:select(S#state.torrent_id, Index),
    {ok, Data, NS} = read_pieces_and_assemble(Operations, [], S),
    DataSize = size(Data),
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
	    %% Make sure there is no chunks left for this piece.
	    ok = etorrent_chunk_mgr:remove_chunks(S#state.torrent_id, Index),
	    ok = etorrent_t_peer_group_mgr:broadcast_have(PeerGroupPid,
							  Index),
	    {noreply, NS};
	false ->
	    ok =
		etorrent_piece_mgr:statechange(S#state.torrent_id,
					       Index,
					       not_fetched),
	    %% TODO: Kill the 'fetched' part in the chunk table.
	    %% TODO: Update 'left' correctly for the piece.
	    {noreply, NS}
    end;
handle_cast(stop, S) ->
    {stop, normal, S};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({'DOWN', _R, process, Pid, _Reason}, S) ->
    Nd = remove_file_process(Pid, S#state.file_process_dict),
    {noreply, S#state { file_process_dict = Nd }};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(shutdown, S) ->
    ok = stop_all_fs_processes(S#state.file_process_dict),
    ok;
terminate(Reason, _State) ->
    error_logger:warning_report([fs_process_terminate, Reason]),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
create_file_process(Id, S) ->
    {ok, Pid} = etorrent_fs_pool_sup:add_file_process(S#state.file_pool, S#state.torrent_id, Id),
    erlang:monitor(process, Pid),
    NewDict = dict:store(Id, Pid, S#state.file_process_dict),
    {ok, Pid, S#state{ file_process_dict = NewDict }}.

read_pieces_and_assemble([], FileData, S) ->
    {ok, list_to_binary(lists:reverse(FileData)), S};
read_pieces_and_assemble([{Id, Offset, Size} | Rest], Done, S) ->
    case dict:find(Id, S#state.file_process_dict) of
	{ok, Pid} ->
	    Ref = make_ref(),
	    case catch({Ref,
			etorrent_fs_process:get_data(Pid, Offset, Size)}) of
		{Ref, Data} ->
		    read_pieces_and_assemble(Rest, [Data | Done], S);
		{'EXIT', {noproc, _}} ->
		    D = remove_file_process(Pid, S#state.file_process_dict),
		    read_pieces_and_assemble([{Id, Offset, Size} | Rest],
					     Done,
					     S#state{file_process_dict = D})
	    end;
	error ->
	    {ok, Pid, NS} = create_file_process(Id, S),
	    Data = etorrent_fs_process:get_data(Pid, Offset, Size),
	    read_pieces_and_assemble(Rest, [Data | Done], NS)
    end.

%%--------------------------------------------------------------------
%% Func: fs_write(Data, Operations, State) -> {ok, State}
%% Description: Write data defined by Operations. Returns new State
%%   maintaining the file_process_dict.
%%--------------------------------------------------------------------
fs_write(<<>>, [], S) ->
    {ok, S};
fs_write(Data, [{Id, Offset, Size} | Rest], S) ->
    <<Chunk:Size/binary, Remaining/binary>> = Data,
    case dict:find(Id, S#state.file_process_dict) of
	{ok, Pid} ->
	    Ref = make_ref(),
	    case catch({Ref,
			etorrent_fs_process:put_data(Pid, Chunk,
						     Offset, Size)}) of
		{Ref, ok} ->
		    fs_write(Remaining, Rest, S);
		{'EXIT', {noproc, _}} ->
		    D = remove_file_process(Pid, S#state.file_process_dict),
		    fs_write(Data, [{Id, Offset, Size} | Rest],
				     S#state{file_process_dict = D})
	    end;
	error ->
	    {ok, Pid, NS} = create_file_process(Id, S),
	    ok = etorrent_fs_process:put_data(Pid, Chunk, Offset, Size),
	    fs_write(Remaining, Rest, NS)
    end.

remove_file_process(Pid, Dict) ->
    case dict:fetch_keys(dict:filter(fun (_K, V) -> V =:= Pid end, Dict)) of
	[Key] ->
	    dict:erase(Key, Dict);
	[] ->
	    ok
    end.

stop_all_fs_processes(Dict) ->
    lists:foreach(fun({_, Pid}) -> etorrent_fs_process:stop(Pid) end,
		  dict:to_list(Dict)),
    ok.



