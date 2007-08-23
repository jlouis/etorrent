%%%-------------------------------------------------------------------
%%% File    : etorrent_t_peer_recv.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% License : See COPYING
%%% Description : Represents a peers receiving of data
%%%
%%% Created : 19 Jul 2007 by
%%%    Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_t_peer_recv).

-behaviour(gen_server).

%% API
-export([start_link/5, connect/3, choke/1, unchoke/1, interested/1,
	 send_have_piece/2, complete_handshake/3, uploaded_data/2,
	stop/1]).

%% Temp API
-export([chunkify/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, { peer_id = none, % TODO: Rename to remote_peer_id
		 local_peer_id = none,
		 info_hash = none,

		 tcp_socket = none,

		 remote_choked = true,
		 remote_interested = false,

		 local_interested = false,

		 request_queue = none,
		 remote_request_set = none,

		 piece_set = none,
		 piece_request = [],

		 file_system_pid = none,
		 master_pid = none,
		 send_pid = none,
		 state_pid = none}).

-define(DEFAULT_CONNECT_TIMEOUT, 120000).
-define(DEFAULT_CHUNK_SIZE, 16384).
-define(BASE_QUEUE_LEVEL, 10).
%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(LocalPeerId, InfoHash, StatePid, FilesystemPid, MasterPid) ->
    gen_server:start_link(?MODULE, [LocalPeerId, InfoHash,
				    StatePid, FilesystemPid, MasterPid], []).

connect(Pid, IP, Port) ->
    gen_server:cast(Pid, {connect, IP, Port}).

choke(Pid) ->
    gen_server:cast(Pid, choke).

unchoke(Pid) ->
    gen_server:cast(Pid, unchoke).

interested(Pid) ->
    gen_server:cast(Pid, interested).

send_have_piece(Pid, PieceNumber) ->
    gen_server:cast(Pid, {send_have_piece, PieceNumber}).

complete_handshake(Pid, ReservedBytes, Socket) ->
    gen_server:cast(Pid, {complete_handshake, ReservedBytes, Socket}).

uploaded_data(Pid, Amount) ->
    gen_server:cast(Pid, {uploaded_data, Amount}).

stop(Pid) ->
    gen_server:cast(Pid, stop).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([LocalPeerId, InfoHash, StatePid, FilesystemPid, MasterPid]) ->
    {ok, #state{ local_peer_id = LocalPeerId,
		 piece_set = sets:new(),
		 request_queue = queue:new(),
		 remote_request_set = sets:new(),
		 info_hash = InfoHash,
		 state_pid = StatePid,
		 master_pid = MasterPid,
		 file_system_pid = FilesystemPid}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(stop, S) ->
    {stop, normal, S};
handle_cast({connect, IP, Port}, S) ->
    case gen_tcp:connect(IP, Port, [binary, {active, false}],
			 ?DEFAULT_CONNECT_TIMEOUT) of
	{ok, Socket} ->
	    case etorrent_peer_communication:initiate_handshake(
		   Socket,
		   S#state.local_peer_id,
		   S#state.info_hash) of
		{ok, _ReservedBytes, PeerId} ->
		    enable_socket_messages(Socket),
		    {ok, SendPid} =
			etorrent_t_peer_send:start_link(Socket,
							S#state.file_system_pid,
							S#state.state_pid),
		    BF = etorrent_t_state:retrieve_bitfield(S#state.state_pid),
		    etorrent_t_peer_send:send(SendPid, {bitfield, BF}),
		    {noreply, S#state{tcp_socket = Socket,
				      peer_id = PeerId,
				      send_pid = SendPid}};
		{error, _X} ->
		    {stop, normal, S}
	    end;
	{error, _Reason} ->
	    {stop, normal, S}
    end;
handle_cast({uploaded_data, Amount}, S) ->
    etorrent_t_peer_group:uploaded_data(S#state.master_pid, Amount),
    {noreply, S};
handle_cast({complete_handshake, _ReservedBytes, Socket}, S) ->
    etorrent_peer_communication:complete_handshake_header(Socket,
						 S#state.info_hash,
						 S#state.local_peer_id),
    enable_socket_messages(Socket),
    {ok, SendPid} =
	etorrent_t_peer_send:start_link(Socket,
				     S#state.file_system_pid,
				     S#state.state_pid),
    BF = etorrent_t_state:retrieve_bitfield(S#state.state_pid),
    etorrent_t_peer_send:send(SendPid, {bitfield, BF}),
    {noreply, S#state{tcp_socket = Socket,
		      send_pid = SendPid}};
handle_cast(choke, S) ->
    etorrent_t_peer_send:choke(S#state.send_pid),
    {noreply, S};
handle_cast(unchoke, S) ->
    etorrent_t_peer_send:unchoke(S#state.send_pid),
    {noreply, S};
handle_cast(interested, S) ->
    case S#state.local_interested of
	true ->
	    {noreply, S};
	false ->
	    send_message(interested, S),
	    {noreply, S#state{local_interested = true}}
    end;
handle_cast({send_have_piece, PieceNumber}, S) ->
    case sets:is_element(PieceNumber, S#state.piece_set) of
	true ->
	    % Peer has the piece, so ignore sending the HAVE message
	    {noreply, S};
	false ->
	    % Peer is missing the piece, so send it.
	    etorrent_t_peer_send:send_have_piece(S#state.send_pid, PieceNumber),
	    {noreply, S}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({tcp_closed, _P}, S) ->
    {stop, normal, S};
handle_info({tcp, _Socket, M}, S) ->
    Msg = etorrent_peer_communication:recv_message(M),
    case handle_message(Msg, S) of
	{ok, NS} ->
	    {noreply, NS};
	{stop, Err, NS} ->
	    {stop, Err, NS}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, S) ->
    ok = etorrent_t_state:remove_bitfield(S#state.state_pid, S#state.piece_set),
    catch(etorrent_t_peer_send:stop(S#state.send_pid)),
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
handle_message(keep_alive, S) ->
    {ok, S};
handle_message(choke, S) ->
    etorrent_t_peer_group:peer_choked(S#state.master_pid),
    NS = unqueue_all_pieces(S),
    {ok, NS#state { remote_choked = true }};
handle_message(unchoke, S) ->
    etorrent_t_peer_group:peer_unchoked(S#state.master_pid),
    try_to_queue_up_pieces(S#state{remote_choked = false});
handle_message(interested, S) ->
    etorrent_t_peer_group:peer_interested(S#state.master_pid),
    {ok, S#state { remote_interested = true}};
handle_message(not_interested, S) ->
    etorrent_t_peer_group:peer_not_interested(S#state.master_pid),
    {ok, S#state { remote_interested = false}};
handle_message({request, Index, Offset, Len}, S) ->
    etorrent_t_peer_send:remote_request(S#state.send_pid, Index, Offset, Len),
    {ok, S};
handle_message({cancel, Index, Offset, Len}, S) ->
    etorrent_t_peer_send:cancel(S#state.send_pid, Index, Offset, Len),
    {ok, S};
handle_message({have, PieceNum}, S) ->
    PieceSet = sets:add_element(PieceNum, S#state.piece_set),
    case etorrent_t_state:remote_have_piece(S#state.state_pid, PieceNum) of
	interested when S#state.local_interested == true ->
	    {ok, S#state{piece_set = PieceSet}};
	interested when S#state.local_interested == false ->
	    send_message(interested, S),
	    {ok, S#state{local_interested = true,
			 piece_set = PieceSet}};
	not_interested ->
	    {ok, S#state{piece_set = PieceSet}}
    end;
handle_message({bitfield, BitField}, S) ->
    case sets:size(S#state.piece_set) of
	0 ->
	    Size = etorrent_t_state:num_pieces(S#state.state_pid),
	    {ok, PieceSet} =
		etorrent_peer_communication:destruct_bitfield(Size, BitField),
	    case etorrent_t_state:remote_bitfield(S#state.state_pid, PieceSet) of
		interested ->
		    send_message(interested, S),
		    {ok, S#state{piece_set = PieceSet,
				 local_interested = true}};
		not_interested ->
		    {ok, S#state{piece_set = PieceSet}};
		not_valid ->
		    {stop, invalid_pieces, S}
	    end;
	N when is_integer(N) ->
	    {stop, got_out_of_band_bitfield, S}
    end;
handle_message({piece, Index, Offset, Data}, S) ->
    Len = size(Data),
    etorrent_t_state:downloaded_data(S#state.state_pid, Len),
    etorrent_t_peer_group:downloaded_data(S#state.master_pid, Len),
    case handle_got_chunk(Index, Offset, Data, Len, S) of
	stop ->
	    {stop, normal, S};
	{ok, NS} ->
	    try_to_queue_up_pieces(NS)
    end;
handle_message(Unknown, S) ->
    {stop, {unknown_message, Unknown}, S}.


delete_piece_from_request_sets(Index, Offset, Len, S) ->
    case sets:is_element({Index, Offset, Len}, S#state.remote_request_set) of
	true ->
	    RemoteRSet = sets:del_element({Index, Offset, Len},
					  S#state.remote_request_set),
	    {ok, S#state{remote_request_set = RemoteRSet}};
	false ->
	    % If the piece is not in the remote request set, the peer has
	    %   sent us a message "out of band". We don't care at all and
	    %   attempt to find it in the request queue instead
	    case etorrent_utils:queue_remove_with_check({Index, Offset, Len},
					       S#state.request_queue) of
		{ok, NQ} ->
		    {ok, S#state{request_queue = NQ}};
		false ->
		    % Bastard sent us something out of band. This *can*
		    % happen in fast choking/unchoking runs!
		    out_of_band
	    end
    end.

get_requests(S) ->
    lists:flatten(lists:map(fun({Index, _, _}) ->
					  io_lib:format("|~B|", [Index])
				  end,
				  S#state.piece_request)).

get_queues(S) ->
    lists:flatten(lists:map(
		    fun({Index, Offset, Len}) ->
			    io_lib:format("|~p|", [{Index, Offset, Len}])
		    end,
		    lists:concat([queue:to_list(S#state.request_queue),
				  sets:to_list(S#state.remote_request_set)]))).

report_errornous_piece(Index, Offset, Len, S) ->
    error_logger:warning_msg(
      "Peer ~s sent us chunk ~p have no piece_request on~nRequests: ~p~n~p~n",
      [S#state.peer_id, {Index, Offset, Len}, get_requests(S), get_queues(S)]).

delete_piece(Index, Offset, Len, S) ->
    case delete_piece_from_request_sets(Index, Offset, Len, S) of
	{ok, NS} ->
	    NS;
	out_of_band ->
	    S
    end.

handle_store_piece(Index, S) ->
    case check_and_store_piece(Index, S) of
	ok ->
	    PR = lists:keydelete(Index, 1, S#state.piece_request),
	    {ok, S#state{piece_request = PR}};
	wrong_hash ->
	    stop
    end.

handle_update_piece(Index, Offset, Len, Data, GBT, N, S) ->
    case update_with_new_piece(Index, Offset, Len, Data, GBT, N, S) of
	{done, NS} ->
	    handle_store_piece(Index, NS);
	{not_done, NS} ->
	    {ok, NS}
    end.

handle_got_chunk(Index, Offset, Data, Len, S) ->
    NS = delete_piece(Index, Offset, Len, S),
    case lists:keysearch(Index, 1, NS#state.piece_request) of
	false ->
	    report_errornous_piece(Index, Offset, Len, NS),
	    stop;
	{value, {_CurrentIndex, GBT, N}} ->
	    handle_update_piece(Index, Offset, Len, Data, GBT, N, NS)
    end.

check_and_store_piece(Index, S) ->
    case lists:keysearch(Index, 1, S#state.piece_request) of
	{value, {_CurrentIndex, GBT, 0}} ->
	    PList = gb_trees:to_list(GBT),
	    ok = invariant_check(PList),
	    Piece = lists:map(
		      fun({_Offset, {_Len, Data}}) ->
			      Data
		      end,
		      PList),
	    case etorrent_fs:write_piece(S#state.file_system_pid,
				    Index,
				    list_to_binary(Piece)) of
		ok ->
		    ok = etorrent_t_state:got_piece_from_peer(
			   S#state.state_pid,
			   Index,
			   piece_size(Piece)),
		    ok = etorrent_t_peer_group:got_piece_from_peer(
			   S#state.master_pid,
			   Index),
		    ok;
		wrong_hash ->
		    wrong_hash
	    end
    end.

piece_size(Data) ->
    lists:foldl(fun(D, Acc) ->
			Acc + size(D)
		end,
		0,
		Data).

invariant_check(PList) ->
    V = lists:foldl(fun (_E, error) -> error;
			({Offset, _T}, N) when Offset /= N ->
			    error;
		        ({_Offset, {Len, Data}}, _N) when Len /= size(Data) ->
			    error;
			({Offset, {Len, _}}, N) when Offset == N ->
			    Offset + Len
		    end,
		    0,
		    PList),
    case V of
	error ->
	    error;
	N when is_integer(N) ->
	    ok
    end.

send_message(Msg, S) ->
    etorrent_t_peer_send:send(S#state.send_pid, Msg).

update_piece_count(X, N) when X == none ->
    N-1;
update_piece_count(_X, N) ->
    N.

update_with_new_piece(Index, Offset, Len, Data, GBT, N, S) ->
    {PLen, Slot} = gb_trees:get(Offset, GBT),
    PLen = Len,
    PiecesLeft = update_piece_count(Slot, N),
    PR = lists:keyreplace(
	   Index, 1, S#state.piece_request,
	   {Index,
	    gb_trees:update(Offset, {Len, Data}, GBT),
	    PiecesLeft}),
    case PiecesLeft of
	0 ->
	    {done, S#state{piece_request = PR}};
	K when integer(K) ->
	    {not_done, S#state{piece_request = PR}}
    end.

%%--------------------------------------------------------------------
%% Function: enable_socketorrent_messages(socket() -> ok
%% Description: Make the socket active and configure it to bittorrent
%%   specifications.
%%--------------------------------------------------------------------
enable_socket_messages(Socket) ->
    inet:setopts(Socket, [binary, {active, true}, {packet, 4}]).

%%--------------------------------------------------------------------
%% Function: unqueue_all_pieces/1
%% Description: Unqueue all queued pieces at the other end. We place
%%   the earlier queued items at the end to compensate for quick
%%   choke/unchoke problems and live data.
%%--------------------------------------------------------------------
unqueue_all_pieces(S) ->
    Requests = sets:to_list(S#state.remote_request_set),
    Q = S#state.request_queue,
    NQ = queue:join(Q, queue:from_list(Requests)),
    S#state{remote_request_set = sets:new(),
	     request_queue = NQ}.

%%--------------------------------------------------------------------
%% Function: try_to_queue_up_requests(state()) -> {ok, state()}
%% Description: Try to queue up requests at the other end. This function
%%  differs from queue_up_requests in the sense it also handles interest
%%  and choking.
%%--------------------------------------------------------------------
try_to_queue_up_pieces(S) when S#state.remote_choked == true ->
    {ok, S};
try_to_queue_up_pieces(S) ->
    PiecesToQueue = ?BASE_QUEUE_LEVEL - sets:size(S#state.remote_request_set),
    case queue_up_requests(S, PiecesToQueue) of
	{ok, NS} ->
	    {ok, NS};
	{partially_queued, NS, Left, not_interested}
	  when Left == ?BASE_QUEUE_LEVEL ->
	    % Out of pieces to give him
	    etorrent_t_peer_send:not_interested(S#state.send_pid),
	    {ok, NS#state{local_interested = false}};
	{partially_queued, NS, _Left, not_interested} ->
	    % We still have some pieces in the queue
	    {ok, NS}
    end.

%%--------------------------------------------------------------------
%% Function: queue_up_requests(state(), N) -> {ok, state()} | ...
%% Description: Try to queue up N requests at the other end.
%%   If no pieces are ready in the queue, attempt to select a piece
%%   for queueing.
%%   Either succeds with {ok, state()} or fails because no piece is
%%   eligible.
%%--------------------------------------------------------------------
queue_up_requests(S, 0) ->
    {ok, S};
queue_up_requests(S, N) ->
    case queue:out(S#state.request_queue) of
	{empty, Q} ->
	    select_piece_for_queueing(S#state{request_queue = Q}, N);
	{{value, {Index, Offset, Len}}, Q} ->
	    etorrent_t_peer_send:local_request(S#state.send_pid,
					    Index, Offset, Len),
	    RS = sets:add_element({Index, Offset, Len},
				  S#state.remote_request_set),
	    queue_up_requests(S#state{request_queue = Q,
				      remote_request_set = RS}, N-1)
    end.

%%--------------------------------------------------------------------
%% Function: select_piece_for_queueing(state(), N) -> ...
%% Description: Select a piece and chunk it up for queueing. Then make
%%  a tail-call into queue_up_requests continuing the queue, or fail
%%  if no piece is eligible.
%%--------------------------------------------------------------------
select_piece_for_queueing(S, N) ->
    true = queue:is_empty(S#state.request_queue),
    case etorrent_t_state:request_new_piece(S#state.state_pid,
					    S#state.piece_set) of
	{ok, PieceNum, PieceSize} ->
	    {ok, Chunks, NumChunks} = chunkify(PieceNum, PieceSize),
	    {ok, ChunkDict} = build_chunk_dict(Chunks),
	    queue_up_requests(S#state{piece_request =
				        [{PieceNum, ChunkDict, NumChunks} |
					 S#state.piece_request],
				      request_queue = queue:from_list(Chunks)},
			      N);
	E when is_atom(E) ->
	    {partially_queued, S, N, E}
    end.

%%--------------------------------------------------------------------
%% Function: chunkify(integer(), integer()) ->
%%  {ok, list_of_chunk(), integer()}
%% Description: From a Piece number and its total size this function
%%  builds the chunks the piece consist of.
%%--------------------------------------------------------------------
chunkify(PieceNum, PieceSize) ->
    chunkify(?DEFAULT_CHUNK_SIZE, 0, PieceNum, PieceSize, []).

chunkify(_ChunkSize, _Offset, _PieceNum, 0, Acc) ->
    {ok, lists:reverse(Acc), length(Acc)};
chunkify(ChunkSize, Offset, PieceNum, Left, Acc)
 when ChunkSize =< Left ->
    chunkify(ChunkSize, Offset+ChunkSize, PieceNum, Left-ChunkSize,
	     [{PieceNum, Offset, ChunkSize} | Acc]);
chunkify(ChunkSize, Offset, PieceNum, Left, Acc) ->
    chunkify(ChunkSize, Offset+Left, PieceNum, 0,
	     [{PieceNum, Offset, Left} | Acc]).

%%--------------------------------------------------------------------
%% Function: build_chunk_dict(list_of_chunks()) -> gb_tree()
%% Description: Build a gb_tree from the chunks suitable for filling
%%  up when the requested pieces come in from the peer.
%%--------------------------------------------------------------------
build_chunk_dict(Chunklist) ->
    Tree = lists:foldl(fun({_Index, Begin, Len}, GBT) ->
			      gb_trees:enter(Begin, {Len, none}, GBT)
		      end,
		      gb_trees:empty(),
		      Chunklist),
    {ok, gb_trees:balance(Tree)}.
