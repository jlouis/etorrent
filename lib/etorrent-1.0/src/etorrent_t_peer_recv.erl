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
-export([start_link/6, connect/3, choke/1, unchoke/1, interested/1,
	 send_have_piece/2, complete_handshake/4, uploaded_data/2,
	stop/1]).

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

		 file_system_pid = none,
		 master_pid = none,
		 send_pid = none,
		 control_pid = none,
		 state_pid = none}).

-define(DEFAULT_CONNECT_TIMEOUT, 120000). % Default timeout in ms
-define(DEFAULT_CHUNK_SIZE, 16384). % Default size for a chunk. All clients use this.
-define(BASE_QUEUE_LEVEL, 10). % How many chunks to keep queued. An advanced client
                               % will fine-tune this number.

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(LocalPeerId, InfoHash, StatePid, FilesystemPid, MasterPid, ControlPid) ->
    gen_server:start_link(?MODULE, [LocalPeerId, InfoHash,
				    StatePid, FilesystemPid, MasterPid, ControlPid], []).

%%--------------------------------------------------------------------
%% Function: connect(Pid, IP, Port)
%% Description: Connect to the IP and Portnumber for communication with
%%   the peer.
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
%% Description: Tell the peer we have just piece PieceNumber.
%%--------------------------------------------------------------------
send_have_piece(Pid, PieceNumber) ->
    gen_server:cast(Pid, {send_have_piece, PieceNumber}).

%%--------------------------------------------------------------------
%% Function: complete_handshake(Pid, ReservedBytes, Socket, PeerId)
%% Description: Complete the handshake initiated by another client.
%%--------------------------------------------------------------------
complete_handshake(Pid, ReservedBytes, Socket, PeerId) ->
    gen_server:cast(Pid, {complete_handshake, ReservedBytes, Socket, PeerId}).

%%--------------------------------------------------------------------
%% Function: uploaded_data(Pid, Amount)
%% Description: Record that we uploaded Amount bytes of data to the peer.
%%--------------------------------------------------------------------
uploaded_data(Pid, Amount) ->
    gen_server:cast(Pid, {uploaded_data, Amount}).

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
init([LocalPeerId, InfoHash, StatePid, FilesystemPid, MasterPid, ControlPid]) ->
    {ok, #state{ local_peer_id = LocalPeerId,
		 piece_set = sets:new(),
		 remote_request_set = sets:new(),
		 info_hash = InfoHash,
		 state_pid = StatePid,
		 master_pid = MasterPid,
		 control_pid = ControlPid,
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
		    ok = enable_socket_messages(Socket),
		    {ok, SendPid} =
			etorrent_t_peer_send:start_link(Socket,
							S#state.file_system_pid,
							S#state.state_pid),
		    BF = etorrent_t_state:retrieve_bitfield(S#state.state_pid),
		    etorrent_t_peer_send:send(SendPid, {bitfield, BF}),
		    {noreply, S#state{tcp_socket = Socket,
				      remote_peer_id = PeerId,
				      send_pid = SendPid}};
		{error, _X} ->
		    {stop, normal, S}
	    end;
	{error, _Reason} ->
	    {stop, normal, S}
    end;
handle_cast({uploaded_data, Amount}, S) ->
    etorrent_mnesia_operations:peer_statechange(self(), {uploaded, Amount}),
    {noreply, S};
handle_cast({complete_handshake, _ReservedBytes, Socket, RemotePeerId}, S) ->
    etorrent_peer_communication:complete_handshake_header(Socket,
						 S#state.info_hash,
						 S#state.local_peer_id),
    ok = enable_socket_messages(Socket),
    {ok, SendPid} =
	etorrent_t_peer_send:start_link(Socket,
				     S#state.file_system_pid,
				     S#state.state_pid),
    BF = etorrent_t_state:retrieve_bitfield(S#state.state_pid),
    etorrent_t_peer_send:send(SendPid, {bitfield, BF}),
    {noreply, S#state{tcp_socket = Socket,
		      send_pid = SendPid,
		      remote_peer_id = RemotePeerId}};
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
    etorrent_t_peer_send:send_have_piece(S#state.send_pid, PieceNumber),
    {noreply, S};
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
    unqueue_all_pieces(S),
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
    etorrent_mnesia_operations:peer_statechange(self(), remote_choking),
    NS = unqueue_all_pieces(S),
    {ok, NS#state { remote_choked = true }};
handle_message(unchoke, S) ->
    etorrent_mnesia_operations:peer_statechange(self(), remote_unchoking),
    try_to_queue_up_pieces(S#state{remote_choked = false});
handle_message(interested, S) ->
    etorrent_mnesia_operations:peer_statechange(self(), interested),
    {ok, S#state { remote_interested = true}};
handle_message(not_interested, S) ->
    etorrent_mnesia_operations:peer_statechange(self(), not_interested),
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
    %% XXX: Consider taking this over to the point where the piece has been checked...
    etorrent_t_state:downloaded_data(S#state.state_pid, Len),
    etorrent_mnesia_operations:peer_statechange(self(), {downloaded, Len}),
    case handle_got_chunk(Index, Offset, Data, Len, S) of
	stop ->
	    {stop, normal, S};
	{ok, NS} ->
	    try_to_queue_up_pieces(NS)
    end;
handle_message(Unknown, S) ->
    {stop, {unknown_message, Unknown}, S}.

delete_piece(Ref, Index, Offset, Len, S) ->
    RS = sets:del_element({Ref, Index, Offset, Len}, S#state.remote_request_set),
    {ok, S#state { remote_request_set = RS}}.

handle_got_chunk(Index, Offset, Data, Len, S) ->
    {atomic, [Ref]} = etorrent_mnesia_chunks:select_chunk(S#state.control_pid, Index, Offset, Len),
    %%% XXX: More stability here. What happens when things fuck up?
    case etorrent_mnesia_chunks:store_chunk(
	   Ref,
	   Data,
	   S#state.state_pid,
	   S#state.file_system_pid,
	   S#state.control_pid) of
	{atomic, _} ->
	    delete_piece(Ref, Index, Offset, Len, S);
	_ ->
	    stop
    end.

send_message(Msg, S) ->
    etorrent_t_peer_send:send(S#state.send_pid, Msg).

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
    etorrent_mnesia_chunks:putback_chunks(lists:map(fun({R, _, _, _}) -> R end,
						    Requests),
					  self()),
    S#state{remote_request_set = sets:new()}.

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
    case etorrent_mnesia_chunks:select_chunks(self(),
					      S#state.control_pid,
					      S#state.piece_set,
					      S#state.state_pid,
					      PiecesToQueue) of
	not_interested ->
	    etorrent_t_peer_send:not_interested(S#state.send_pid),
	    {ok, S#state { local_interested = false}};
	{atomic, Items} ->
	    queue_items(Items, S)
    end.

queue_items([], S) ->
    {ok, S};
queue_items([Chunk | Chunks], S) ->
    etorrent_t_peer_send:local_request(S#state.send_pid,
				       Chunk#chunk.piece_number,
				       Chunk#chunk.offset,
				       Chunk#chunk.size),
    RS = sets:add_element({Chunk#chunk.ref,
			   Chunk#chunk.piece_number,
			   Chunk#chunk.offset,
			   Chunk#chunk.size}, S#state.remote_request_set),
    queue_items(Chunks, S#state { remote_request_set = RS }).

