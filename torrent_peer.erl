-module(torrent_peer).
-behaviour(gen_server).

-export([init/1, handle_cast/2, handle_info/2, handle_call/3, terminate/2]).
-export([code_change/3]).

-export([start_link/1, get_states/1, choke/1, unchoke/1, interested/1, not_interested/1]).

-record(cstate, {my_state = {choking, not_interested},
		 his_state = {choking, not_intersted},
		 socket = none,
		 transmitting = no,
		 connection_manager_pid = no,
		 name = no,
		 send_pid = no}).

init({Socket, ConnectionManagerPid, Name}) ->
    {ok, #cstate{socket = Socket,
			      connection_manager_pid = ConnectionManagerPid,
			      name = Name}}.

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
    {noreply, send_unchoke(State)}.

handle_info({'EXIT', _FromPid, Reason}, State) ->
    error_logger:warning_msg("Recv loop exited: ~s~n", [Reason]),
    %% There is nothing to do. If our recv_loop is dead we can't make anything out of the receiving
    %% socket.
    gen_tcp:close(State#cstate.socket),
    exit(recv_loop_died).

handle_call(get_states, _Who, State) ->
    {reply, {State#cstate.my_state,
	     State#cstate.his_state}}.

%% Message handling code
handle_message(keep_alive, State) ->
    %% This is just sent at a certain interval to keep the line alive. It can be totally ignored.
    %% It is probably mostly there to please firewalls state tracking and NAT.
    State;
handle_message(choke, State) ->
    %% This is sent if we have been choked upstream. We can't do anything about it locally, so
    %% we are just going to alter our local state.
    {_Choke, Interest} = State#cstate.his_state,
    State#cstate{his_state = {choked, Interest}};
handle_message(interested, State) ->
    %% The peer just got interested in our pieces. Wohoo!
    {Choke, _Interest} = State#cstate.his_state,
    connection_manager:is_interested(State#cstate.connection_manager_pid),
    State#cstate{his_state = {Choke, interested}};
handle_message(not_interested, State) ->
    {Choke, _Interest} = State#cstate.his_state,
    connection_manager:is_not_intersted(State#cstate.connection_manager_pid),
    State#cstate{his_state = {Choke, not_interested}}.

send_message(State, Message) ->
    State#cstate.send_pid ! {datagram, Message}.

%% To be used for piece sending later on.
%% send_message_reply(State, Message) ->
%%     State#cstate.send_pid ! {reply_datagram, Message}.

send_choke(State) ->
    send_message(State, choke),
    {_Choked, Interested} = State#cstate.my_state,
    State#cstate{my_state = {choked, Interested}}.

send_unchoke(State) ->
    send_message(State, unchoke),
    {_Choked, Interested} = State#cstate.my_state,
    State#cstate{my_state = {unchoked, Interested}}.

%% send_interested(State) ->
%%     send_message(State, interested),
%%     {Choked, _Interested} = State#cstate.my_state,
%%     State#cstate{my_state = {Choked, intersted}}.

%% send_not_interested(State) ->
%%     send_message(State, not_intersted),
%%     {Choked, _Interested} = State#cstate.my_state,
%%     State#cstate{my_state = {Choked, not_intersted}}.

%% Calls
start_link(Socket) ->
    gen_server:start_link(torrent_peer, Socket, []).

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
