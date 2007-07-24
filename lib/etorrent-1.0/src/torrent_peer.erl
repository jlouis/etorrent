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
-export([start_link/5, connect/2]).
-export([send_message/2]). % TODO: Make this local

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
		 local_choked  = true,
		 local_interested = false,

		 send_pid = none,
		 state_pid = none}).

-define(DEFAULT_CONNECT_TIMEOUT, 120000).


%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(IP, Port, PeerId, InfoHash, StatePid) ->
    gen_server:start_link(?MODULE, [IP, Port, PeerId, InfoHash, StatePid], []).

connect(Pid, MyPeerId) ->
    gen_server:cast(Pid, {connect, MyPeerId}).

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
init([IP, Port, PeerId, InfoHash, StatePid]) ->
    {ok, #state{ ip = IP,
		 port = Port,
		 peer_id = PeerId,
		 info_hash = InfoHash,
		 state_pid = StatePid}}.

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
	    {ok, SendPid} = torrent_peer_send:start_link(Socket),
	    BF = torrent_state:retrieve_bitfield(S#state.state_pid),
	    torrent_peer_send:send(SendPid, {bitfield, BF}),
	    {noreply, S#state{tcp_socket = Socket,
			      send_pid = SendPid}};
	{error, X} ->
	    exit(X)
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
terminate(_Reason, _State) ->
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
    {ok, S#state { remote_choked = true }};
handle_message(unchoke, S) ->
    {ok, S#state { remote_choked = false }};
handle_message(Unknown, S) ->
    {stop, {unknown_message, Unknown}, S}.

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

enable_socket_messages(Socket) ->
    inet:setopts(Socket, [binary, {active, true}, {packet, 4}]).
