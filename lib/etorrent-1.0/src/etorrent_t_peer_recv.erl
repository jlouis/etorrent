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

-include("etorrent_mnesia_table.hrl").
-include("etorrent_rate.hrl").

%% API
-export([start_link/6, connect/3, choke/1, unchoke/1, interested/1,
	 send_have_piece/2, complete_handshake/4, endgame_got_chunk/2,
	 queue_pieces/1, stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, { remote_peer_id = none,
		 local_peer_id = none,
		 info_hash = none,

		 tcp_socket = none,

		 remote_choked = true,

		 local_interested = false,

		 remote_request_set = none,

		 piece_set = none,
		 piece_request = [],

		 packet_left = none,
		 packet_iolist = [],

		 endgame = false, % Are we in endgame mode?

		 parent = none,

		 file_system_pid = none,
		 send_pid = none,

		 rate = none,
		 rate_timer = none,
		 torrent_id = none}).

-define(DEFAULT_CONNECT_TIMEOUT, 120000). % Default timeout in ms
-define(DEFAULT_CHUNK_SIZE, 16384). % Default size for a chunk. All clients use this.
-define(HIGH_WATERMARK, 15). % How many chunks to queue up to
-define(LOW_WATERMARK, 5).  % Requeue when there are less than this number of pieces in queue
%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(LocalPeerId, InfoHash, FilesystemPid, Id, Parent,
	  {IP, Port}) ->
    gen_server:start_link(?MODULE, [LocalPeerId, InfoHash,
				    FilesystemPid, Id, Parent,
				    {IP, Port}], []).

%%--------------------------------------------------------------------
%% Function: stop/1
%% Args: Pid ::= pid()
%% Description: Gracefully ask the server to stop.
%%--------------------------------------------------------------------
stop(Pid) ->
    gen_server:cast(Pid, stop).

%%--------------------------------------------------------------------
%% Function: connect(Pid, IP, Port)
%% Description: Connect to the IP and Portnumber for communication with
%%   the peer. Note we don't handle the connect in the init phase. This is
%%   due to the fact that a connect may take a considerable amount of time.
%%   With this scheme, we spawn off processes, and then make them all attempt
%%   connects in parallel, which is much easier.
%%--------------------------------------------------------------------
connect(Pid, IP, Port) ->
    gen_server:cast(Pid, {connect, IP, Port}).

%%--------------------------------------------------------------------
%% Function: choke(Pid)
%% Description: Choke the peer.
%%--------------------------------------------------------------------
choke(Pid) ->
    gen_server:cast(Pid, choke).

%%--------------------------------------------------------------------
%% Function: unchoke(Pid)
%% Description: Unchoke the peer.
%%--------------------------------------------------------------------
unchoke(Pid) ->
    gen_server:cast(Pid, unchoke).

%%--------------------------------------------------------------------
%% Function: interested(Pid)
%% Description: Tell the peer we are interested.
%%--------------------------------------------------------------------
interested(Pid) ->
    gen_server:cast(Pid, interested).

%%--------------------------------------------------------------------
%% Function: send_have_piece(Pid, PieceNumber)
%% Description: Tell the peer we have just recieved piece PieceNumber.
%%--------------------------------------------------------------------
send_have_piece(Pid, PieceNumber) ->
    gen_server:cast(Pid, {send_have_piece, PieceNumber}).

%%--------------------------------------------------------------------
%% Function: endgame_got_chunk(Pid, Index, Offset) -> ok
%% Description: We got the chunk {Index, Offset}, handle it.
%%--------------------------------------------------------------------
endgame_got_chunk(Pid, Chunk) ->
    gen_server:cast(Pid, {endgame_got_chunk, Chunk}).

%%--------------------------------------------------------------------
%% Function: complete_handshake(Pid, ReservedBytes, Socket, PeerId)
%% Description: Complete the handshake initiated by another client.
%%--------------------------------------------------------------------
complete_handshake(Pid, ReservedBytes, Socket, PeerId) ->
    gen_server:cast(Pid, {complete_handshake, ReservedBytes, Socket, PeerId}).

queue_pieces(Pid) ->
    gen_server:cast(Pid, queue_pieces).

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
init([LocalPeerId, InfoHash, FilesystemPid, Id, Parent, {IP, Port}]) ->
    process_flag(trap_exit, true),
    {ok, TRef} = timer:send_interval(?RATE_UPDATE, self(), rate_update),
    %% TODO: Update the leeching state to seeding when peer finished torrent.
    ok = etorrent_peer:new(IP, Port, Id, self(), leeching),
    {ok, #state{
       parent = Parent,
       local_peer_id = LocalPeerId,
       piece_set = gb_sets:new(),
       remote_request_set = gb_trees:empty(),
       info_hash = InfoHash,
       torrent_id = Id,
       rate = etorrent_rate:init(?RATE_FUDGE),
       rate_timer = TRef,
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
    {reply, Reply, State, 0}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({connect, IP, Port}, S) ->
    case gen_tcp:connect(IP, Port, [binary, {active, false}],
			 ?DEFAULT_CONNECT_TIMEOUT) of
	{ok, Socket} ->
	    case etorrent_peer_communication:initiate_handshake(
		   Socket,
		   S#state.local_peer_id,
		   S#state.info_hash) of
		{ok, _ReservedBytes, PeerId}
		  when PeerId == S#state.local_peer_id ->
		    {stop, normal, S};
		{ok, _ReservedBytes, PeerId} ->
		    complete_connection_setup(S#state { tcp_socket = Socket,
						        remote_peer_id = PeerId});
		{error, _} ->
		    {stop, normal, S}
	    end;
	{error, _Reason} ->
	    {stop, normal, S}
    end;
handle_cast({complete_handshake, _ReservedBytes, Socket, RemotePeerId}, S) ->
    case etorrent_peer_communication:complete_handshake(Socket,
							S#state.info_hash,
							S#state.local_peer_id) of
	ok -> complete_connection_setup(S#state { tcp_socket = Socket,
						  remote_peer_id = RemotePeerId });
	{error, stop} -> {stop, normal, S}
    end;
handle_cast(choke, S) ->
    etorrent_t_peer_send:choke(S#state.send_pid),
    {noreply, S, 0};
handle_cast(unchoke, S) ->
    etorrent_t_peer_send:unchoke(S#state.send_pid),
    {noreply, S, 0};
handle_cast(interested, S) ->
    {noreply, statechange_interested(S, true), 0};
handle_cast({send_have_piece, PieceNumber}, S) ->
    etorrent_t_peer_send:send_have_piece(S#state.send_pid, PieceNumber),
    {noreply, S, 0};
handle_cast({endgame_got_chunk, Chunk}, S) ->
    NS = handle_endgame_got_chunk(Chunk, S),
    {noreply, NS, 0};
handle_cast(queue_pieces, S) ->
    {ok, NS} = try_to_queue_up_pieces(S),
    {noreply, NS, 0};
handle_cast(stop, S) ->
    {stop, normal, S};
handle_cast(_Msg, State) ->
    {noreply, State, 0}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(timeout, S) ->
    case gen_tcp:recv(S#state.tcp_socket, 0, 3000) of
	{ok, Packet} ->
	    handle_read_from_socket(S, Packet);
	{error, closed} ->
	    {stop, normal, S};
	{error, ebadf} ->
	    {stop, normal, S};
	{error, etimedout} ->
	    {noreply, S, 0};
	{error, timeout} when S#state.remote_choked =:= true ->
	    {noreply, S, 0};
	{error, timeout} when S#state.remote_choked =:= false ->
	    {ok, NS} = try_to_queue_up_pieces(S),
	    {noreply, NS, 0}
    end;
handle_info(rate_update, S) ->
    Rate = etorrent_rate:update(S#state.rate, 0),
    ok = etorrent_rate_mgr:recv_rate(S#state.torrent_id, self(), Rate#peer_rate.rate, 0),
    {noreply, S#state { rate = Rate}, 0};
handle_info(_Info, State) ->
    {noreply, State, 0}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(Reason, S) ->
    etorrent_peer:delete(self()),
    _NS = unqueue_all_pieces(S),
    case S#state.tcp_socket of
	none ->
	    ok;
	Sock ->
	    gen_tcp:close(Sock)
    end,
    case Reason of
	normal -> ok;
	shutdown -> ok;
	_ -> error_logger:info_report([reason_for_termination, Reason])
    end,
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

%%--------------------------------------------------------------------
%% Func: handle_message(Msg, State) -> {ok, NewState} | {stop, Reason, NewState}
%% Description: Process an incoming message Msg from the wire. Return either
%%  {ok, S} if the processing was ok, or {stop, Reason, S} in case of an error.
%%--------------------------------------------------------------------
handle_message(keep_alive, S) ->
    {ok, S};
handle_message(choke, S) ->
    ok = etorrent_rate_mgr:choke(S#state.torrent_id, self()),
    NS = unqueue_all_pieces(S),
    {ok, NS#state { remote_choked = true }};
handle_message(unchoke, S) ->
    ok = etorrent_rate_mgr:unchoke(S#state.torrent_id, self()),
    try_to_queue_up_pieces(S#state{remote_choked = false});
handle_message(interested, S) ->
    ok = etorrent_rate_mgr:interested(S#state.torrent_id, self()),
    ok = etorrent_t_peer_send:check_choke(S#state.send_pid),
    {ok, S};
handle_message(not_interested, S) ->
    ok = etorrent_rate_mgr:not_interested(S#state.torrent_id, self()),
    ok = etorrent_t_peer_send:check_choke(S#state.send_pid),
    {ok, S};
handle_message({request, Index, Offset, Len}, S) ->
    etorrent_t_peer_send:remote_request(S#state.send_pid, Index, Offset, Len),
    {ok, S};
handle_message({cancel, Index, Offset, Len}, S) ->
    etorrent_t_peer_send:cancel(S#state.send_pid, Index, Offset, Len),
    {ok, S};
handle_message({have, PieceNum}, S) ->
    case etorrent_piece_mgr:valid(S#state.torrent_id, PieceNum) of
	true ->
	    PieceSet = gb_sets:add_element(PieceNum, S#state.piece_set),
	    NS = S#state{piece_set = PieceSet},
	    case etorrent_piece_mgr:interesting(S#state.torrent_id, PieceNum) of
		true when S#state.local_interested =:= true ->
		    try_to_queue_up_pieces(S);
		true when S#state.local_interested =:= false ->
		    try_to_queue_up_pieces(statechange_interested(S, true));
		false ->
		    {ok, NS}
	    end;
	false ->
	    {ok, {IP, Port}} = inet:peername(S#state.tcp_socket),
	    etorrent_bad_peer_mgr:enter_peer(IP, Port, S#state.remote_peer_id),
	    {stop, normal, S}
    end;
handle_message({bitfield, BitField}, S) ->
    case gb_sets:size(S#state.piece_set) of
	0 ->
	    Size = etorrent_torrent:num_pieces(S#state.torrent_id),
	    {ok, PieceSet} =
		etorrent_peer_communication:destruct_bitfield(Size, BitField),
	    case etorrent_piece_mgr:check_interest(S#state.torrent_id, PieceSet) of
		interested ->
		    {ok, statechange_interested(S#state {piece_set = PieceSet},
						true)};
		not_interested ->
		    {ok, S#state{piece_set = PieceSet}};
		invalid_piece ->
		    {stop, {invalid_piece_2, S#state.remote_peer_id}, S}
	    end;
	N when is_integer(N) ->
	    %% This is a bad peer. Kill him!
	    {ok, {IP, Port}} = inet:peername(S#state.tcp_socket),
	    etorrent_bad_peer_mgr:enter_peer(IP, Port, S#state.remote_peer_id),
	    {stop, normal, S}
    end;
handle_message({piece, Index, Offset, Data}, S) ->
    case handle_got_chunk(Index, Offset, Data, size(Data), S) of
	{ok, NS} ->
	    try_to_queue_up_pieces(NS)
    end;
handle_message(Unknown, S) ->
    {stop, {unknown_message, Unknown}, S}.


%%--------------------------------------------------------------------
%% Func: handle_endgame_got_chunk(Index, Offset, S) -> State
%% Description: Some other peer just downloaded {Index, Offset, Len} so try
%%   not to download it here if we can avoid it.
%%--------------------------------------------------------------------
handle_endgame_got_chunk({Index, Offset, Len}, S) ->
    case gb_trees:is_defined({Index, Offset, Len}, S#state.remote_request_set) of
	true ->
	    %% Delete the element from the request set.
	    RS = gb_trees:delete({Index, Offset, Len}, S#state.remote_request_set),
	    etorrent_t_peer_send:cancel(S#state.send_pid,
					Index,
					Offset,
					Len),
	    etorrent_chunk_mgr:endgame_remove_chunk(S#state.send_pid,
						    S#state.torrent_id,
						    {Index, Offset, Len}),
	    S#state { remote_request_set = RS };
	false ->
	    %% Not an element in the request queue, ignore
	    etorrent_chunk_mgr:endgame_remove_chunk(S#state.send_pid,
						    S#state.torrent_id,
						    {Index, Offset, Len}),
	    S
    end.

%%--------------------------------------------------------------------
%% Func: handle_got_chunk(Index, Offset, Data, Len, S) -> {ok, State}
%% Description: We just got some chunk data. Store it in the mnesia DB
%%--------------------------------------------------------------------
handle_got_chunk(Index, Offset, Data, Len, S) ->
    case gb_trees:lookup({Index, Offset, Len},
			 S#state.remote_request_set) of
	{value, Ops} ->
	    ok = etorrent_fs:write_chunk(S#state.file_system_pid,
					 {Index, Data, Ops}),
	    case etorrent_chunk_mgr:store_chunk(S#state.torrent_id,
						Index,
						{Offset, Len},
						self()) of
		full ->
		    etorrent_fs:check_piece(S#state.file_system_pid, Index);
		ok ->
		    ok
	    end,
	    %% Tell other peers we got the chunk if in endgame
	    case S#state.endgame of
		true ->
		    case etorrent_chunk_mgr:mark_fetched(S#state.torrent_id,
						     {Index, Offset, Len}) of
			found ->
			    ok;
			assigned ->
			    broadcast_got_chunk({Index, Offset, Len}, S#state.torrent_id)
		    end;
		false ->
		    ok
	    end,
	    RS = gb_trees:delete_any({Index, Offset, Len}, S#state.remote_request_set),
	    {ok, S#state { remote_request_set = RS }};
	none ->
	    %% Stray piece, we could try to get hold of it but for now we just
	    %%   throw it on the floor.
	    {ok, S}
    end.

%%--------------------------------------------------------------------
%% Function: unqueue_all_pieces/1
%% Description: Unqueue all queued pieces at the other end. We place
%%   the earlier queued items at the end to compensate for quick
%%   choke/unchoke problems and live data.
%%--------------------------------------------------------------------
unqueue_all_pieces(S) ->
    %% Put chunks back
    ok = etorrent_chunk_mgr:putback_chunks(self()),
    %% Tell other peers that there is 0xf00d!
    broadcast_queue_pieces(S#state.torrent_id),
    %% Clean up the request set.
    S#state{remote_request_set = gb_trees:empty()}.

%%--------------------------------------------------------------------
%% Function: try_to_queue_up_requests(state()) -> {ok, state()}
%% Description: Try to queue up requests at the other end.
%%--------------------------------------------------------------------
try_to_queue_up_pieces(S) when S#state.remote_choked == true ->
    {ok, S};
try_to_queue_up_pieces(S) ->
    case gb_trees:size(S#state.remote_request_set) of
	N when N > ?LOW_WATERMARK ->
	    {ok, S};
	%% Optimization: Only replenish pieces modulo some N
	N when is_integer(N) ->
	    PiecesToQueue = ?HIGH_WATERMARK - N,
	    case etorrent_chunk_mgr:pick_chunks(self(),
						S#state.torrent_id,
						S#state.piece_set,
						PiecesToQueue) of
		not_interested ->
		    {ok, statechange_interested(S, false)};
		none_eligible ->
		    {ok, S};
		{ok, Items} ->
		    queue_items(Items, S);
		{endgame, Items} ->
		    queue_items(Items, S#state { endgame = true })
	    end
    end.

%%--------------------------------------------------------------------
%% Function: queue_items/2
%% Args:     ChunkList ::= [CompactChunk | ExplicitChunk]
%%           S         ::= #state
%%           CompactChunk ::= {PieceNumber, ChunkList}
%%           ExplicitChunk ::= {PieceNumber, Offset, Size, Ops}
%%           ChunkList ::= [{Offset, Size, Ops}]
%%           PieceNumber, Offset, Size ::= integer()
%%           Ops ::= file_operations - described elsewhere.
%% Description: Send chunk messages for each chunk we decided to queue.
%%   also add these chunks to the piece request set.
%%--------------------------------------------------------------------
queue_items(ChunkList, S) ->
    RSet = queue_items(ChunkList, S#state.send_pid, S#state.remote_request_set),
    {ok, S#state { remote_request_set = RSet }}.

queue_items([], _SendPid, Tree) -> Tree;
queue_items([{Pn, Chunks} | Rest], SendPid, Tree) ->
    NT = lists:foldl(
      fun ({Offset, Size, Ops}, T) ->
	      case gb_trees:is_defined({Pn, Offset, Size}, T) of
		  true ->
		      Tree;
		  false ->
		      etorrent_t_peer_send:local_request(SendPid,
							 {Pn, Offset, Size}),
		      gb_trees:enter({Pn, Offset, Size}, Ops, T)
	      end
      end,
      Tree,
      Chunks),
    queue_items(Rest, SendPid, NT);
queue_items([{Pn, Offset, Size, Ops} | Rest], SendPid, Tree) ->
    NT = case gb_trees:is_defined({Pn, Offset, Size}, Tree) of
	     true ->
		 Tree;
	     false ->
		 etorrent_t_peer_send:local_request(SendPid,
						    {Pn, Offset, Size}),
		 gb_trees:enter({Pn, Offset, Size}, Ops, Tree)
	 end,
    queue_items(Rest, SendPid, NT).

%%--------------------------------------------------------------------
%% Function: complete_connection_setup() -> gen_server_reply()}
%% Description: Do the bookkeeping needed to set up the peer:
%%    * enable passive messaging mode on the socket.
%%    * Start the send pid
%%    * Send off the bitfield
%%--------------------------------------------------------------------
complete_connection_setup(S) ->
    {ok, SendPid} = etorrent_t_peer_sup:add_sender(S#state.parent,
						   S#state.tcp_socket,
						   S#state.file_system_pid,
						   S#state.torrent_id,
						   self()),
    BF = etorrent_piece_mgr:bitfield(S#state.torrent_id),
    etorrent_t_peer_send:bitfield(SendPid, BF),

    {noreply, S#state{send_pid = SendPid}, 0}.

statechange_interested(S, What) ->
    etorrent_t_peer_send:interested(S#state.send_pid),
    S#state{local_interested = What}.


%%--------------------------------------------------------------------
%% Function: handle_read_from_socket(State, Packet) -> NewState
%%             Packet ::= binary()
%%             State  ::= #state()
%% Description: Packet came in. Handle it.
%%--------------------------------------------------------------------
handle_read_from_socket(S, <<>>) ->
    {noreply, S, 0};
handle_read_from_socket(S, <<0:32/big-integer, Rest/binary>>) when S#state.packet_left =:= none ->
    handle_read_from_socket(S, Rest);
handle_read_from_socket(S, <<Left:32/big-integer, Rest/binary>>) when S#state.packet_left =:= none ->
    handle_read_from_socket(S#state { packet_left = Left,
				      packet_iolist = []}, Rest);
handle_read_from_socket(S, Packet) when is_binary(S#state.packet_left) ->
    H = S#state.packet_left,
    handle_read_from_socket(S#state { packet_left = none },
			    <<H/binary, Packet/binary>>);
handle_read_from_socket(S, Packet) when size(Packet) < 4, S#state.packet_left =:= none ->
    {noreply, S#state { packet_left = Packet }};
handle_read_from_socket(S, Packet)
  when size(Packet) >= S#state.packet_left, is_integer(S#state.packet_left) ->
    Left = S#state.packet_left,
    <<Data:Left/binary, Rest/binary>> = Packet,
    Left = size(Data),
    P = iolist_to_binary(lists:reverse([Data | S#state.packet_iolist])),
    {Msg, Rate, Amount} = etorrent_peer_communication:recv_message(S#state.rate, P),
    case Msg of
	{piece, _, _ ,_} ->
	    ok = etorrent_rate_mgr:recv_rate(S#state.torrent_id,
					     self(), Rate#peer_rate.rate,
					     Amount, last_update);
	_Msg ->
	    ok = etorrent_rate_mgr:recv_rate(S#state.torrent_id,
					     self(), Rate#peer_rate.rate,
					     Amount, normal)
    end,
    case handle_message(Msg, S#state {rate = Rate}) of
	{ok, NS} ->
	    handle_read_from_socket(NS#state { packet_left = none,
					       packet_iolist = []},
				    Rest);
	{stop, Err, NS} ->
	    {stop, Err, NS}
    end;
handle_read_from_socket(S, Packet)
  when size(Packet) < S#state.packet_left, is_integer(S#state.packet_left) ->
    {noreply, S#state { packet_iolist = [Packet | S#state.packet_iolist],
		        packet_left = S#state.packet_left - size(Packet) }, 0}.

broadcast_queue_pieces(TorrentId) ->
    Peers = etorrent_peer:all(TorrentId),
    lists:foreach(fun (P) ->
			  etorrent_t_peer_recv:queue_pieces(P#peer.pid)
		  end,
		  Peers).

broadcast_got_chunk(Chunk, TorrentId) ->
    Peers = etorrent_peer:all(TorrentId),
    lists:foreach(fun (Peer) ->
			  etorrent_t_peer_recv:endgame_got_chunk(Peer#peer.pid, Chunk)
		  end,
		  Peers).

