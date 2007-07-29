%%%-------------------------------------------------------------------
%%% File    : torrent_peer.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Represents a peer
%%%
%%% Created : 19 Jul 2007 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(torrent_peer).

-behaviour(gen_server).

%% API
-export([start_link/7, connect/2, choke/1, unchoke/1, interested/1]).

%% Temp API
-export([chunkify/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, { ip = none,
		 port = none,
		 peer_id = none,
		 info_hash = none,

		 tcp_socket = none,

		 remote_choked = true,
		 remote_interested = false,

		 local_interested = false,

		 request_queue = none,
		 remote_request_set = none,

		 piece_set = none,
		 piece_request = none,

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
start_link(IP, Port, PeerId, InfoHash, StatePid, FilesystemPid, MasterPid) ->
    gen_server:start_link(?MODULE, [IP, Port, PeerId, InfoHash,
				    StatePid, FilesystemPid, MasterPid], []).

connect(Pid, MyPeerId) ->
    gen_server:cast(Pid, {connect, MyPeerId}).

choke(Pid) ->
    gen_server:cast(Pid, choke).

unchoke(Pid) ->
    gen_server:cast(Pid, unchoke).

interested(Pid) ->
    gen_server:cast(Pid, interested).

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
init([IP, Port, PeerId, InfoHash, StatePid, FilesystemPid, MasterPid]) ->
    {ok, #state{ ip = IP,
		 port = Port,
		 peer_id = PeerId,
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
handle_cast({connect, MyPeerId}, S) ->
    Socket = int_connect(S#state.ip, S#state.port),
    case peer_communication:initiate_handshake(Socket,
					       S#state.peer_id,
					       MyPeerId,
					       S#state.info_hash) of
	{ok, _ReservedBytes} ->
	    enable_socket_messages(Socket),
	    {ok, SendPid} =
		torrent_peer_send:start_link(Socket,
					     S#state.file_system_pid,
					     S#state.state_pid,
					     S#state.master_pid),
	    %sys:trace(SendPid, true),
	    BF = torrent_state:retrieve_bitfield(S#state.state_pid),
	    torrent_peer_send:send(SendPid, {bitfield, BF}),
	    {noreply, S#state{tcp_socket = Socket,
			      send_pid = SendPid}};
	{error, X} ->
	    exit(X)
    end;
handle_cast(choke, S) ->
    torrent_peer_send:choke(S#state.send_pid),
    {noreply, S};
handle_cast(unchoke, S) ->
    torrent_peer_send:unchoke(S#state.send_pid),
    {noreply, S};
handle_cast(interested, S) ->
    case S#state.local_interested of
	true ->
	    {noreply, S};
	false ->
	    send_message(interested, S),
	    {noreply, S#state{local_interested = true}}
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
    Msg = peer_communication:recv_message(M),
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
    ok = torrent_state:remove_bitfield(S#state.state_pid, S#state.piece_set),
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
    torrent_peer_master:peer_choked(S#state.master_pid),
    {ok, S#state { remote_choked = true }};
handle_message(unchoke, S) ->
    torrent_peer_master:peer_unchoked(S#state.master_pid),
    try_to_queue_up_pieces(S#state{remote_choked = false});
handle_message(interested, S) ->
    torrent_peer_master:peer_interested(S#state.master_pid),
    {ok, S#state { remote_interested = true}};
handle_message(not_interested, S) ->
    torrent_peer_master:peer_not_interested(S#state.master_pid),
    {ok, S#state { remote_interested = false}};
handle_message({request, Index, Offset, Len}, S) ->
    torrent_peer_send:remote_request(S#state.send_pid, Index, Offset, Len),
    {ok, S};
handle_message({cancel, Index, Offset, Len}, S) ->
    torrent_peer_send:cancel(S#state.send_pid, Index, Offset, Len),
    {ok, S};
handle_message({have, PieceNum}, S) ->
    PieceSet = sets:add_element(PieceNum, S#state.piece_set),
    case torrent_state:remote_have_piece(S#state.state_pid, PieceNum) of
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
	    Size = torrent_state:num_pieces(S#state.state_pid),
	    {ok, PieceSet} =
		peer_communication:destruct_bitfield(Size, BitField),
	    case torrent_state:remote_bitfield(S#state.state_pid, PieceSet) of
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
    torrent_state:downloaded_data(S#state.state_pid, Len),
    torrent_peer_master:downloaded_data(S#state.master_pid, Len),
    case handle_got_chunk(Index, Offset, Data, Len, S) of
	fail ->
	    {stop, error_in_got_chunk, S};
	{ok, NS} ->
	    try_to_queue_up_pieces(NS)
    end;
handle_message(Unknown, S) ->
    {stop, {unknown_message, Unknown}, S}.

handle_got_chunk(Index, Offset, Data, Len, S) ->
    true = sets:is_element({Index, Offset, Len}, S#state.remote_request_set),
    RemoteRSet = sets:del_element({Index, Offset, Len},
				  S#state.remote_request_set),
    case lists:keysearch(Index, 1, S#state.piece_request) of
	false ->
	    fail;
	{value, {_CurrentIndex, GBT, 1}} ->
	    NS = update_with_new_piece(Index, Offset, Len, Data, GBT, 1, S),
	    ok = check_and_store_piece(Index, NS),
	    PR = lists:keydelete(Index, 1, NS#state.piece_request),
	    {ok, NS#state{piece_request = PR,
			  remote_request_set = RemoteRSet}};
	{value, {_CurrentIndex, GBT, N}} ->
	    {ok, update_with_new_piece(
		   Index, Offset, Len, Data, GBT, N,
		   S#state{remote_request_set = RemoteRSet})}
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
	    case file_system:write_piece(S#state.file_system_pid,
				    Index,
				    list_to_binary(Piece)) of
		ok ->
		    ok = torrent_state:got_piece_from_peer(
			   S#state.state_pid,
			   Index,
			   piece_size(Piece)),
		    ok;
		fail ->
		    piece_error
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
    torrent_peer_send:send(S#state.send_pid, Msg).

% Specialize connects to our purpose
int_connect(IP, Port) ->
    case gen_tcp:connect(IP, Port, [binary, {active, false}],
			 ?DEFAULT_CONNECT_TIMEOUT) of
	{ok, Socket} ->
	    Socket;
	{error, _Reason} ->
	    exit(normal)
    end.

update_with_new_piece(Index, Offset, Len, Data, GBT, N, S) ->
    case gb_trees:get(Offset, GBT) of
	{PLen, none} when PLen == Len ->
	    PR = lists:keyreplace(
		   Index, 1, S#state.piece_request,
		   {Index,
		    gb_trees:update(Offset, {Len, Data}, GBT),
		    N-1}),
	    S#state{piece_request = PR}
    end.

%%--------------------------------------------------------------------
%% Function: enable_socket_messages(socket() -> ok
%% Description: Make the socket active and configure it to bittorrent
%%   specifications.
%%--------------------------------------------------------------------
enable_socket_messages(Socket) ->
    inet:setopts(Socket, [binary, {active, true}, {packet, 4}]).

%%--------------------------------------------------------------------
%% Function: try_toqueue_up_requests(state()) -> {ok, state()}
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
	    torrent_peer_send:not_interested(S#state.send_pid),
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
	    torrent_peer_send:local_request(S#state.send_pid,
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
    case torrent_state:request_new_piece(S#state.state_pid,
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
