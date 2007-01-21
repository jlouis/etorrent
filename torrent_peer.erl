-module(torrent_peer).
-behaviour(gen_server).

-export([init/1, handle_cast/2, handle_info/2, handle_call/3, terminate/2]).
-export([code_change/3]).

-export([start_link/1, get_states/1]).

-record(communication_state, {my_state = {choking, not_interested},
			      his_state = {choking, not_intersted},
			      socket = none}).

init(Socket) ->
    {ok, #communication_state{socket = Socket}}.

terminate(shutdown, State) ->
    gen_tcp:close(State#communication_state.socket),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

recv_loop(Socket, Master) ->
    Message = peer_communication:recv_message(Socket),
    gen_server:cast(Master, {packet_received, Message}),
    torrent_peer:recv_loop(Socket, Master).

handle_cast(startup, State) ->
    spawn_link(fun(Socket, Pid) -> recv_loop(Socket, Pid) end,
	       [State#communication_state.socket, self()]),
    {noreply, State};
handle_cast({receive_message, Message}, State) ->
    NewState = handle_message(Message, State),
    {noreply, NewState}.

handle_info({'EXIT', _FromPid, Reason}, State) ->
    error_logger:warning_msg("Recv loop exited: ~s~n", [Reason]),
    %% There is nothing to do. If our recv_loop is dead we can't make anything out of the receiving
    %% socket.
    gen_tcp:close(State#communication_state.socket),
    exit(recv_loop_died).

handle_call(get_states, _Who, State) ->
    {reply, {State#communication_state.my_state,
	     State#communication_state.his_state}}.

%% Message handling code
handle_message(keep_alive, State) ->
    State.

%% Calls
start_link(Socket) ->
    gen_server:start_link(torrent_peer, Socket, []).

get_states(Pid) ->
    gen_server:call(Pid, get_states).
