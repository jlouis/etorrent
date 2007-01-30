%%%-------------------------------------------------------------------
%%% File    : torrent_peer.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus>
%%% Description : Connection code to the peer
%%%
%%% Created : 24 Jan 2007 by Jesper Louis Andersen <jlouis@succubus>
%%%-------------------------------------------------------------------
-module(torrent_peer).
-author("Jesper Louis Andersen <jesper.louis.andersen@gmail.com>").
-behaviour(gen_server).

%% API
-export([start_link/5, startup_connect/3, startup_accept/2,
	 choke/1, unchoke/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-export([queue_requests/4]).

-record(state, {me_choking = true,
		me_interested = false,
		he_choking = true,
		he_interested = false,
		his_pieces = none,
		socket = none,
		transmitting = false,
		connection_manager_pid = no,
		peerid = no,
		infohash = no,
		name = no,
		send_pid = no,
		his_peerid = no,
		filesystem_pid = no,
		piecemap_pid = no,
		his_requested_queue = no,
		my_requested = no,
		piece_table = no,
	        torrent_id = no}).

%% Default number of pieces to keep queued at other end.
-define(REQUEST_QUEUE_SIZE, 5).

%%====================================================================
%% API
%%====================================================================
start_link(ConnectionManager, FileSystem, Name, PeerId, InfoHash) ->
    gen_server:start_link(torrent_peer, {ConnectionManager,
					 FileSystem,
					 Name,
					 PeerId,
					 InfoHash}, []).

startup_connect(Pid, IP, Port) ->
    gen_server:cast(Pid, {startup_connect, IP, Port}).

startup_accept(Pid, ListenSock) ->
    gen_server:cast(Pid, {startup_accept, ListenSock}).

choke(Pid) ->
    gen_server:cast(Pid, choke).

unchoke(Pid) ->
    gen_server:cast(Pid, unchoke).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init({ConnectionManagerPid, FileSystemPid, Name, PeerId, InfoHash}) ->
    {ok, #state{connection_manager_pid = ConnectionManagerPid,
		filesystem_pid = FileSystemPid,
		name = Name,
		peerid = PeerId,
		infohash = InfoHash,
		his_requested_queue = queue:new(),
		his_pieces = sets:new(),
		my_requested = sets:new()}}.

handle_call(Request, From, State) ->
    error_logger:error_report([Request, From]),
    Reply = ok,
    {reply, Reply, State}.

handle_connect(Socket, S) ->
    SendPid = torrent_peer_send:start_link(Socket,
					   self(),
					   S#state.peerid,
					   S#state.infohash),
    {ok, HisPeerId} = peer_communication:recv_handshake(Socket,
							S#state.peerid,
							S#state.infohash),
    enable_messages(S#state.socket),
    {ok, PiecesWeHave, TotalPieces} =
	torrent_piecemap:pieces_downloaded(S#state.piecemap_pid),
    torrent_peer_send:send_bitfield(S#state.send_pid,
				   PiecesWeHave,
				   TotalPieces),
    {ok, SendPid, HisPeerId}.

handle_cast({startup_connect, IP, Port}, S) ->
    {ok, Sock} = gen_tcp:connect(IP, Port, [binary, {active, false}]),
    {ok, SendPid, HisPeerId} = handle_connect(Sock, S),
    {noreply, S#state{send_pid = SendPid,
		      his_peerid = HisPeerId}};
handle_cast({startup_accept, ListenSock}, S) ->
    {ok, Socket} = gen_tcp:accept(ListenSock),
    {ok, SendPid, HisPeerId} = handle_connect(Socket, S),
    gen_server:cast(S#state.connection_manager_pid, new_accept_needed),
    {noreply, S#state{send_pid = SendPid,
		      his_peerid = HisPeerId}};
handle_cast(choke, S) ->
    torrent_peer_send:send_choke(S#state.send_pid),
    {noreply, S#state{me_choking = true}};
handle_cast(unchoke, S) ->
    torrent_peer_send:send_unchoke(S#state.send_pid),
    {noreply, S#state{me_choking = false}};
handle_cast(datagram_sent, State) ->
    case State#state.me_choking of
	true ->
	    {noreply, State};
	false ->
	    {noreply, transmit_next_piece(State#state{transmitting = false})}
    end;
handle_cast(Msg, State) ->
    error_logger:error_report([Msg, State]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({tcp, _Socket, Msg}, S) ->
    Decoded = peer_communication:recv_message(Msg),
    {noreply, handle_message(Decoded, S)};
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
    case S#state.socket of
	none ->
	    ok;
	X ->
	    gen_tcp:close(X)
    end.

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
%% Func: handle_message(Msg, State)
%% Description: Handle an incoming message
%%--------------------------------------------------------------------
handle_message(keep_alive, State) ->
    %% This is just sent at a certain interval to keep the line alive.
    %%   It can be totally ignored.
   State;
handle_message(choke, State) ->
    State#state{he_choking = true};
handle_message(interested, State) ->
    connection_manager:is_interested(State#state.connection_manager_pid,
				     State#state.peerid),
    State#state{he_interested = true};
handle_message({have, PieceNum}, S) ->
    NewS = S#state{his_pieces = sets:add_element(PieceNum,
						 S#state.his_pieces)},
    case torrent_piecemap:peer_got_piece(S#state.piecemap_pid,
					 PieceNum) of
	interested ->
	    RQSize = sets:size(S#state.my_requested),
	    if
		RQSize =< ?REQUEST_QUEUE_SIZE ->
		    attempt_to_queue_pieces(NewS)
	    end;
	not_interested ->
	    NewS
    end;
handle_message({piece, Index, Begin, Len, Data}, S) ->
    filesystem:store_piece(S#state.filesystem_pid, Index, Begin, Len, Data),
    case dequeue_request(Index, Begin, Len, S) of
	{ok, NS} ->
	    attempt_to_queue_pieces(NS);
	{error, never_queued} ->
	    exit(never_queued) %% May be optimized later on!
    end;
handle_message(not_interested, State) ->
    connection_manager:is_not_interested(State#state.connection_manager_pid,
					 State#state.peerid),
    State#state{he_interested = false};
handle_message({cancel, Index, Begin, Len}, State) ->
    %% Canceling a message is equivalent to deleting it from the queue
    NewQ = remove_from_queue({Index, Begin, Len},
			     State#state.his_requested_queue),
    State#state{his_requested_queue = NewQ};
handle_message({bitfield, BitField}, S) ->
    {ok, _, AllPieces} = torrent_piecemap:pieces_downloaded(
			   S#state.piecemap_pid),
    {ok, PieceSet} = peer_communication:destruct_bitfield(AllPieces,
							  BitField),
    case sets:size(S#state.his_pieces) of
	0 ->
	    NS = S#state{his_pieces = PieceSet},
	    attempt_to_queue_pieces(NS);
	_ ->
	    exit(peer_sent_bitfield_later_on)
    end;
handle_message({request, Index, Begin, Len}, State) ->
    case State#state.me_choking of
	true ->
	    {noreply, insert_into_his_queue({Index, Begin, Len}, State)};
	false ->
	    NS = insert_into_his_queue({Index, Begin, Len}, State),
	    {noreply, transmit_next_piece(NS)}
    end.

transmit_next_piece(State) ->
    case State#state.transmitting of
	true ->
	    State;
	false ->
	    case queue:out(State#state.his_requested_queue) of
		{{value, {Index, Begin, Len}}, Q} ->
		    transmit_piece(Index, Begin, Len, State),
		    State#state{his_requested_queue = Q,
				 transmitting = true};
		{empty, _Q} ->
		    State
	    end
    end.

transmit_piece(Index, Begin, Len, S) ->
    Data = filesystem:request_piece(
	     S#state.filesystem_pid, Index, Begin, Len),
    torrent_peer_send:send_reply_datagram(S#state.send_pid,
					  {piece, Index, Begin, Len, Data}).

insert_into_his_queue(Item, State) ->
    Q = queue:in(Item, State#state.his_requested_queue),
    State#state{his_requested_queue = Q}.

remove_from_queue(Item, Q) ->
    %% This is probably _slow_, but who cares unless
    %% the profiler quacks like a duck?
    queue:from_list(lists:delete(Item, queue:to_list(Q))).

enable_messages(Socket) ->
    inet:setopts(Socket, [binary, {active, true}, {packet, 4}]).


queue_requests(0, FromQ, ToQ, _S) ->
    {done, FromQ, ToQ};
queue_requests(N, FromQ, ToSet, S) ->
    case queue:is_empty(FromQ) of
	true ->
	    case fetch_new_from_queue(S) of
		{ok, NFQ} ->
		    queue_requests(N, NFQ, ToSet, S);
		no_interesting_piece ->
		    {not_interested, N, ToSet}
	    end;
	false ->
	    {{value, Item}, NQ} = queue:out(FromQ),
	    TNQ = sets:add_element(Item, ToSet),
	    torrent_peer_send:send_request(S#state.send_pid, Item),
	    queue_requests(N-1, NQ, TNQ, S)
    end.

fetch_new_from_queue(S) ->
    case torrent_piecemap:request_piece(S#state.piecemap_pid,
					S#state.torrent_id,
					S#state.piece_table) of
	{ok, RequestList} ->
	    {ok, queue:from_list(RequestList)};
	no_interesting_piece ->
	    no_interesting_piece
    end.


attempt_to_queue_pieces(_S) ->
    exit(define_me).

dequeue_request(Index, Begin, Len, S) ->
    case sets:is_element({Index, Begin, Len}, S#state.my_requested) of
	true ->
	    {ok, S#state{my_requested = sets:del_element({Index, Begin, Len},
							 S#state.my_requested)}};
	false ->
	    {error, never_queued}
    end.
