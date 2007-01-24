-module(connection_manager).
-behaviour(gen_server).

-export([handle_call/3, init/1, terminate/2, code_change/3, handle_info/2, handle_cast/2]).

-export([is_interested/2, is_not_interested/2, start_link/3,
	 spawn_new_torrent/6]).

-export([socket_connect/5]).

-record(state, {state_table = none,
		filesystem = none,
		peerid = none,
		infohash = none,
		managed_pids = none}).

start_link(FileSystemPid, PeerId, InfoHash) ->
    gen_server:start_link(connection_manager,
			  {FileSystemPid, PeerId, InfoHash}, []).

init({FileSystemPid, PeerId, InfoHash}) ->
    {ok, #state{state_table = ets:new(connection_table, []),
		filesystem = FileSystemPid,
		peerid = PeerId,
		infohash = InfoHash,
		managed_pids = dict:new()}}.

handle_info({'EXIT', Who, Reason}, S) ->
    error_logger:error_report([Who, Reason]),
    PeerId = dict:fetch(Who, S#state.managed_pids),
    ets:delete(PeerId, S#state.state_table),
    {noreply, S#state{managed_pids = dict:erase(Who, S#state.managed_pids)}};
handle_info(Message, State) ->
    error_logger:error_report([Message, State]),
    {noreply, State}.

handle_call(Message, Who, State) ->
    error_logger:error_msg("M: ~s -- F: ~s~n", [Message, Who]),
    {noreply, State}.

terminate(shutdown, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_cast({new_ip, Port, IP}, S) ->
    spawn_socket_connect(IP, Port, S),
    {noreply, S};
handle_cast({connect_socket, Socket, HisPeerId}, S) ->
    Pid = torrent_peer:start_link(Socket, self(),
				  S#state.filesystem,
				  "FOO",
				  S#state.peerid,
				  S#state.infohash),
    torrent_peer:startup(Pid),
    ets:insert_new(S#state.state_table, {HisPeerId, not_interested, choked}),
    {noreply, S#state{managed_pids = dict:store(S#state.managed_pids,
					        Pid, HisPeerId)}};
handle_cast({is_interested, PeerId}, State) ->
    [{_, _, Choke}] = ets:lookup(State, PeerId),
    {noreply, ets:insert_new(State, {PeerId, interested, Choke})};
handle_cast({is_not_interested, PeerId}, State) ->
    [{_, _, Choke}] = ets:lookup(State, PeerId),
    {norelpy, ets:insert_new(State, {PeerId, not_interested, Choke})};
handle_cast({choked, PeerId}, State) ->
    [{_, I, _}] = ets:lookup(State, PeerId),
    {noreply, ets:insert_new(State, {PeerId, I, choked})};
handle_cast({unchoked, PeerId}, State) ->
    [{_, I, _}] = ets:lookup(State, PeerId),
    {noreply, ets:insert_new(State, {PeerId, I, unchoked})}.

is_interested(Pid, PeerId) ->
    gen_server:cast(Pid, {is_interested, PeerId}).

is_not_interested(Pid, PeerId) ->
    gen_server:cast(Pid, {is_not_intersted, PeerId}).

spawn_new_torrent(Socket, FileSystem, Name, PeerId, InfoHash, S) ->
    Pid = torrent_peer:start_link(Socket, self(), FileSystem, Name, PeerId,
				  InfoHash),
    S#state{managed_pids = dict:store(Pid, PeerId, S#state.managed_pids)}.

socket_connect(Pid, IP, Port, PeerId, InfoHash) ->
    {ok, Sock} = gen_tcp:connect(IP, Port, [binary, {active, false}]),
    {ok, HisPeerId} = peer_communication:recv_handshake(Sock,
							PeerId,
							InfoHash),
    gen_server:cast(Pid, {connect, Sock, HisPeerId}),
    exit(normal).

spawn_socket_connect(IP, Port, S) ->
    spawn(connection_manager, socket_connect, [self(), IP, Port,
					       S#state.peerid,
					       S#state.infohash]).
