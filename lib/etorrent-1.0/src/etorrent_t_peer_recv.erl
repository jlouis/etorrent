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

%% API
-export([start_link/5, connect/3, choke/1, unchoke/1, interested/1,
	 send_have_piece/2, complete_handshake/4,
	 stop/1, endgame_got_chunk/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, { remote_peer_id = none,
		 local_peer_id = none,
		 info_hash = none,

		 tcp_socket = none,

		 remote_choked = true,
		 remote_interested = false,

		 local_interested = false,

		 remote_request_set = none,

		 piece_set = none,
		 piece_request = [],

		 endgame = false, % Are we in endgame mode?

		 file_system_pid = none,
		 peer_group_pid = none,
		 send_pid = none,

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
start_link(LocalPeerId, InfoHash, FilesystemPid, GroupPid, Id) ->
    gen_server:start_link(?MODULE, [LocalPeerId, InfoHash,
				    FilesystemPid, GroupPid, Id], []).

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

%%--------------------------------------------------------------------
%% Function: stop(Pid)
%% Description: Stop this peer.
%%--------------------------------------------------------------------
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
init([LocalPeerId, InfoHash, FilesystemPid, GroupPid, Id]) ->
    {ok, #state{ local_peer_id = LocalPeerId,
		 piece_set = gb_sets:new(),
		 remote_request_set = gb_sets:new(),
		 info_hash = InfoHash,
		 peer_group_pid = GroupPid,
		 torrent_id = Id,
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
handle_cast({uploaded_data, Amount}, S) ->
    etorrent_peer:statechange(self(), {uploaded, Amount}),
    {noreply, S};
handle_cast({complete_handshake, _ReservedBytes, Socket, RemotePeerId}, S) ->
    etorrent_peer_communication:complete_handshake_header(Socket,
						 S#state.info_hash,
						 S#state.local_peer_id),
    complete_connection_setup(S#state { tcp_socket = Socket,
					remote_peer_id = RemotePeerId });
handle_cast(choke, S) ->
    etorrent_t_peer_send:choke(S#state.send_pid),
    {noreply, S};
handle_cast(unchoke, S) ->
    etorrent_t_peer_send:unchoke(S#state.send_pid),
    {noreply, S};
handle_cast(interested, S) ->
    etorrent_t_peer_send:interested(S#state.send_pid),
    {noreply, S#state{local_interested = true}};
handle_cast({send_have_piece, PieceNumber}, S) ->
    etorrent_t_peer_send:send_have_piece(S#state.send_pid, PieceNumber),
    {noreply, S};
handle_cast({endgame_got_chunk, Chunk}, S) ->
    NS = handle_endgame_got_chunk(Chunk, S),
    {noreply, NS};
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
terminate(Reason, S) ->
    unqueue_all_pieces(S),
    case S#state.tcp_socket of
	none ->
	    ok;
	Sock ->
	    gen_tcp:close(Sock)
    end,
    case Reason of
	normal ->
	    ok;
	_ ->
	    error_logger:info_report([reason_for_termination, Reason])
    end,
    etorrent_t_peer_send:stop(S#state.send_pid),
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
    {atomic, ok} = etorrent_peer:statechange(self(), remote_choking),
    NS = unqueue_all_pieces(S),
    {ok, NS#state { remote_choked = true }};
handle_message(unchoke, S) ->
    error_logger:info_report([peer_unchoked, S#state.remote_peer_id]),
    {atomic, ok} = etorrent_peer:statechange(self(), remote_unchoking),
    try_to_queue_up_pieces(S#state{remote_choked = false});
handle_message(interested, S) ->
    {atomic, ok} = etorrent_peer:statechange(self(), interested),
    {ok, S#state { remote_interested = true}};
handle_message(not_interested, S) ->
    etorrent_peer:statechange(self(), not_interested),
    {ok, S#state { remote_interested = false}};
handle_message({request, Index, Offset, Len}, S) ->
    etorrent_t_peer_send:remote_request(S#state.send_pid, Index, Offset, Len),
    {ok, S};
handle_message({cancel, Index, Offset, Len}, S) ->
    etorrent_t_peer_send:cancel(S#state.send_pid, Index, Offset, Len),
    {ok, S};
handle_message({have, PieceNum}, S) ->
    case etorrent_piece:piece_valid(S#state.torrent_id, PieceNum) of
	true ->
	    PieceSet = gb_sets:add_element(PieceNum, S#state.piece_set),
	    NS = S#state{piece_set = PieceSet},
	    case etorrent_piece:piece_interesting(S#state.torrent_id, PieceNum) of
		true when S#state.local_interested =:= true ->
		    {ok, NS};
		true when S#state.local_interested =:= false ->
		    etorrent_t_peer_send:interested(S#state.send_pid),
		    {ok, NS#state{local_interested = true}};
		false ->
		    {ok, NS}
	    end;
	false ->
	    {stop, {invalid_piece, S#state.remote_peer_id}, S}
    end;
handle_message({bitfield, BitField}, S) ->
    case gb_sets:size(S#state.piece_set) of
	0 ->
	    Size = etorrent_torrent:get_num_pieces(S#state.torrent_id),
	    {ok, PieceSet} =
		etorrent_peer_communication:destruct_bitfield(Size, BitField),
	    case etorrent_piece:check_interest(S#state.torrent_id, PieceSet) of
		interested ->
		    etorrent_t_peer_send:interested(S#state.send_pid),
		    {ok, S#state{piece_set = PieceSet,
				 local_interested = true}};
		not_interested ->
		    {ok, S#state{piece_set = PieceSet}};
		invalid_piece ->
		    {stop, {invalid_pieces, S#state.remote_peer_id}, S}
	    end;
	N when is_integer(N) ->
	    %% This is a bad peer. Kill him!
	    {stop, normal, S}
    end;
handle_message({piece, Index, Offset, Data}, S) ->
    Len = size(Data),
    etorrent_peer:statechange(self(), {downloaded, Len}),
    case handle_got_chunk(Index, Offset, Data, Len, S) of
	{ok, NS} ->
	    try_to_queue_up_pieces(NS)
    end;
handle_message(Unknown, S) ->
    {stop, {unknown_message, Unknown}, S}.


%%--------------------------------------------------------------------
%% Func: handle_endgame_got_chunk(Index, Offset, S) -> State
%% Description: Some other peer just downloaded {Index, Offset} so try
%%   not to download it here if we can avoid it.
%%--------------------------------------------------------------------
handle_endgame_got_chunk({Index, Offset, Len}, S) ->
    case gb_sets:is_element({Index, Offset, Len}, S#state.remote_request_set) of
	true ->
	    %% Delete the element from the request set.
	    RS = gb_sets:del_element({Index, Offset, Len}, S#state.remote_request_set),
	    etorrent_t_peer_send:cancel(S#state.send_pid,
					Index,
					Offset,
					Len),
	    etorrent_chunk:endgame_remove_chunk(S#state.send_pid,
						S#state.torrent_id,
						{Index, Offset, Len}),
	    S#state { remote_request_set = RS };
	false ->
	    %% Not an element in the request queue, ignore
	    etorrent_chunk:endgame_remove_chunk(S#state.send_pid,
						S#state.torrent_id,
						{Index, Offset, Len}),
	    S
    end.

%%--------------------------------------------------------------------
%% Func: handle_got_chunk(Index, Offset, Data, Len, S) -> {ok, State}
%% Description: We just got some chunk data. Store it in the mnesia DB
%%   TODO: This is one of the functions which is a candidate for optimization!
%%--------------------------------------------------------------------
handle_got_chunk(Index, Offset, Data, Len, S) ->
    case etorrent_chunk:store_chunk(S#state.torrent_id,
				    Index,
				    {Offset, Len},
				    Data,
				    self()) of
	full ->
	    etorrent_piece:store_piece(S#state.torrent_id,
				       Index,
				       S#state.file_system_pid,
				       S#state.peer_group_pid);
	ok ->
	    ok
    end,
    %% Tell other peers we got the chunk if in endgame
    case S#state.endgame of
	true ->
	    etorrent_t_peer_group:broadcast_got_chunk(
	      S#state.peer_group_pid,
	      {Index, Offset, Len});
	false ->
	    ok
    end,
    RS = gb_sets:del_element({Index, Offset, Len}, S#state.remote_request_set),
    {ok, S#state { remote_request_set = RS }}.

%%--------------------------------------------------------------------
%% Function: unqueue_all_pieces/1
%% Description: Unqueue all queued pieces at the other end. We place
%%   the earlier queued items at the end to compensate for quick
%%   choke/unchoke problems and live data.
%%   TODO: Optimization candidate!
%%--------------------------------------------------------------------
unqueue_all_pieces(S) ->
    etorrent_chunk:putback_chunks(self()),
    S#state{remote_request_set = gb_sets:new()}.

%%--------------------------------------------------------------------
%% Function: try_to_queue_up_requests(state()) -> {ok, state()}
%% Description: Try to queue up requests at the other end.
%%   TODO: This function should use watermarks rather than this puny implementation.
%%--------------------------------------------------------------------
try_to_queue_up_pieces(S) when S#state.remote_choked == true ->
    {ok, S};
%%
%% If we are in endgame, then we can just skip stuff
try_to_queue_up_pieces(S) when S#state.endgame =:= true ->
    {ok, S};
try_to_queue_up_pieces(S) ->
    case gb_sets:size(S#state.remote_request_set) of
	N when N > ?LOW_WATERMARK ->
	    {ok, S};
	%% XXX: This case can be optimized since we don't have
	%% to request pieces all the time. We can reduce it to every 5th, every 10th
	%% Or maybe even statechange.
	N when is_integer(N) ->
	    PiecesToQueue = ?HIGH_WATERMARK - N,
	    case etorrent_chunk:pick_chunks(self(),
					    S#state.torrent_id,
					    S#state.piece_set,
					    PiecesToQueue) of
		not_interested ->
		    etorrent_t_peer_send:not_interested(S#state.send_pid),
		    {ok, S#state { local_interested = false}};
		{ok, Items} ->
		    queue_items(Items, S);
		{endgame, Items} ->
		    error_logger:info_report([entering_endgame]),
		    queue_items(Items, S#state { endgame = true })
	    end
    end.

%%--------------------------------------------------------------------
%% Function: queue_chunks([Chunk], State) -> {ok, State}
%% Description: Send chunk messages for each chunk we decided to queue.
%%   also add these chunks to the piece request set.
%%--------------------------------------------------------------------
queue_items(ChunkList, S) ->
    F = fun
	    ({Pn, Chunks}) ->
		lists:foreach(
		  fun
		      ({Offset, Size}) ->
			  etorrent_t_peer_send:local_request(S#state.send_pid,
							     {Pn, Offset, Size})
		  end,
		  Chunks);
	    ({Pn, Offset, Size}) ->
		etorrent_t_peer_send:local_request(S#state.send_pid,
						   {Pn, Offset, Size})
	end,
    lists:foreach(F, ChunkList),

    G = fun
	    ({Pn, Chunks}, RS) ->
		lists:foldl(fun ({Offset, Size}, RRS) ->
				      gb_sets:add_element({Pn, Offset, Size}, RRS)
			    end,
			    RS,
			    Chunks);
	    ({Pn, Offset, Size}, RS) ->
		gb_sets:add_element({Pn, Offset, Size}, RS)
	end,
    RSet = lists:foldl(G, S#state.remote_request_set, ChunkList),
    {ok, S#state { remote_request_set = RSet }}.

%%--------------------------------------------------------------------
%% Function: complete_connection_setup() -> gen_server_reply()}
%% Description: Do the bookkeeping needed to set up the peer:
%%    * enable passive messaging mode on the socket.
%%    * Start the send pid
%%    * Send off the bitfield
%%--------------------------------------------------------------------
complete_connection_setup(S) ->
    ok = inet:setopts(S#state.tcp_socket,
		      [binary, {active, true}, {packet, 4}]),

    {ok, SendPid} =
	etorrent_t_peer_send:start_link(S#state.tcp_socket,
					S#state.file_system_pid,
					S#state.torrent_id),

    BF = etorrent_piece:get_bitfield(S#state.torrent_id),
    etorrent_t_peer_send:bitfield(SendPid, BF),

    {noreply, S#state{send_pid = SendPid}}.
