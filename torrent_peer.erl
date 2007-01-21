-module(torrent_peer).
-behaviour(gen_server).

-export([init/1, handle_cast/2, handle_info/2, handle_call/3, terminate/2]).
-export([code_change/3]).

-export([start_link/4, get_states/1, choke/1, unchoke/1, interested/1, not_interested/1]).

-record(cstate, {me_choking = true,
		 me_interested = false,
		 he_choking = true,
		 he_interested = false,
		 socket = none,
		 transmitting = false,
		 connection_manager_pid = no,
		 name = no,
		 send_pid = no,
		 filesystem_pid = no,
		 his_requested_queue = no,
		 my_requested_queue = no}).

init({Socket, ConnectionManagerPid, FileSystemPid, Name}) ->
    {ok, #cstate{socket = Socket,
		 connection_manager_pid = ConnectionManagerPid,
		 filesystem_pid = FileSystemPid,
		 name = Name,
		 his_requested_queue = queue:new(),
		 my_requested_queue = queue:new()}}.

terminate(shutdown, State) ->
    gen_tcp:close(State#cstate.socket),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

recv_loop(Socket, Master) ->
    Message = peer_communication:recv_message(Socket),
    gen_server:cast(Master, {packet_received, Message}),
    torrent_peer:recv_loop(Socket, Master).

send_loop(Socket, Master) ->
    receive
	{datagram, Message} ->
	    ok = peer_communication:send_message(Socket, Message);
	{reply_datagram, Message} ->
	    ok = peer_communication:send_message(Socket, Message),
	    gen_server:cast(Master, datagram_sent)
    end,
    torrent_peer:send_loop(Socket, Master).

handle_cast(startup, State) ->
    spawn_link(fun(Socket, Pid) -> recv_loop(Socket, Pid) end,
	       [State#cstate.socket, self()]),
    SendPid = spawn_link(fun(Socket, Pid) -> send_loop(Socket, Pid) end,
			 [State#cstate.socket, self()]),
    {noreply, State#cstate{send_pid = SendPid}};
handle_cast({receive_message, Message}, State) ->
    NewState = handle_message(Message, State),
    {noreply, NewState};
handle_cast(choke, State) ->
    {noreply, send_choke(State)};
handle_cast(unchoke, State) ->
    {noreply, send_unchoke(State)};
handle_cast(datagram_sent, State) ->
    case State#cstate.me_choking of
	true ->
	    {noreply, State};
	false ->
	    {noreply, transmit_next_piece(State#cstate{transmitting = false})}
    end.

handle_info({'EXIT', _FromPid, Reason}, State) ->
    error_logger:warning_msg("Recv loop exited: ~s~n", [Reason]),
    %% There is nothing to do. If our recv_loop is dead we can't make anything out of the receiving
    %% socket.
    gen_tcp:close(State#cstate.socket),
    exit(recv_loop_died).

handle_call(get_states, _Who, State) ->
    {reply, {State#cstate.me_choking, State#cstate.me_interested,
	     State#cstate.he_choking, State#cstate.he_interested}}.

%% Message handling code
handle_message(keep_alive, State) ->
    %% This is just sent at a certain interval to keep the line alive. It can be totally ignored.
    %% It is probably mostly there to please firewalls state tracking and NAT.
    State;
handle_message(choke, State) ->
    State#cstate{he_choking = true};
handle_message(interested, State) ->
    connection_manager:is_interested(State#cstate.connection_manager_pid),
    State#cstate{he_interested = true};
handle_message(not_interested, State) ->
    connection_manager:is_not_intersted(State#cstate.connection_manager_pid),
    State#cstate{he_interested = false};
handle_message({cancel, Index, Begin, Len}, State) ->
    %% Canceling a message is equivalent to deleting it from the queue
    NewQ = remove_from_queue({Index, Begin, Len}, State#cstate.his_requested_queue),
    State#cstate{his_requested_queue = NewQ};
handle_message({request, Index, Begin, Len}, State) ->
    case State#cstate.me_choking of
	true ->
	    {noreply, insert_into_his_queue({Index, Begin, Len}, State)};
	false ->
	    NS = insert_into_his_queue({Index, Begin, Len}, State),
	    {noreply, transmit_next_piece(NS)}
    end.

transmit_next_piece(State) ->
    case State#cstate.transmitting of
	true ->
	    State;
	false ->
	    case queue:out(State#cstate.his_requested_queue) of
		{{value, {Index, Begin, Len}}, Q} ->
		    transmit_piece(Index, Begin, Len, State),
		    State#cstate{his_requested_queue = Q,
				 transmitting = yes};
		{empty, _Q} ->
		    State
	    end
    end.

transmit_piece(Index, Begin, Len, State) ->
    Data = filesystem:request_piece(State#cstate.filesystem_pid, Index, Begin, Len),
    send_message_reply(State, {piece, Index, Begin, Len, Data}).


insert_into_his_queue(Item, State) ->
    Q = queue:in(State#cstate.his_requested_queue, Item),
    State#cstate{his_requested_queue = Q}.

remove_from_queue(Item, Q) ->
    %% This is probably _slow_, but who cares unless the profiler quacks like a duck?
    queue:from_list(lists:delete(Item, queue:to_list(Q))).

send_message(State, Message) ->
    State#cstate.send_pid ! {datagram, Message}.

send_message_reply(State, Message) ->
    State#cstate.send_pid ! {reply_datagram, Message}.

send_choke(State) ->
    send_message(State, choke),
    State#cstate{me_choking = yes}.

send_unchoke(State) ->
    send_message(State, unchoke),
    State#cstate{me_choking = false}.

%% send_interested(State) ->
%%     send_message(State, interested),
%%     {Choked, _Interested} = State#cstate.my_state,
%%     State#cstate{my_state = {Choked, intersted}}.

%% send_not_interested(State) ->
%%     send_message(State, not_intersted),
%%     {Choked, _Interested} = State#cstate.my_state,
%%     State#cstate{my_state = {Choked, not_intersted}}.

%% Calls
start_link(Socket, ConnectionManager, FileSystem, Name) ->
    gen_server:start_link(torrent_peer, {Socket, ConnectionManager, FileSystem, Name}, []).

get_states(Pid) ->
    gen_server:call(Pid, get_states).

choke(Pid) ->
    gen_server:cast(Pid, choke).

unchoke(Pid) ->
    gen_server:cast(Pid, unchoke).

interested(Pid) ->
    gen_server:cast(Pid, interested).

not_interested(Pid) ->
    gen_server:cast(Pid, not_intersted).
