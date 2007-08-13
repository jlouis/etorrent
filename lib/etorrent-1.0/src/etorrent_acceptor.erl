%%%-------------------------------------------------------------------
%%% File    : acceptor.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% Description : Accept new connections from the network.
%%%
%%% Created : 30 Jul 2007 by Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_acceptor).

-behaviour(gen_server).

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, { listen_socket = none}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(ListenSocket) ->
    gen_server:start_link(?MODULE, [ListenSocket], []).

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
init([ListenSocket]) ->
    {ok, #state{ listen_socket = ListenSocket}, 0}.

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
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(timeout, S) ->
    case gen_tcp:accept(S#state.listen_socket) of
	{ok, Socket} ->
	    handshake(Socket),
	    {noreply, S, 0};
	{error, closed} ->
	    {noreply, S, 0};
	{error, E} ->
	    {stop, E}
    end.

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

handshake(Socket) ->
    case etorrent_peer_communication:recieve_handshake(Socket) of
	{ok, ReservedBytes, InfoHash, PeerId} ->
	    lookup_infohash(Socket, ReservedBytes, InfoHash, PeerId);
	{error, Reason} ->
	    error_logger:info_report([acceptor_handshake, Reason]),
	    gen_tcp:close(Socket),
	    ok
    end.

lookup_infohash(Socket, ReservedBytes, InfoHash, PeerId) ->
    case etorrent_t_mapper:lookup(InfoHash) of
	{ok, Pid} ->
	    inform_peer_master(Socket, Pid, ReservedBytes, PeerId);
	not_found ->
	    error_logger:info_report([connection_on_unknown_infohash,
				      InfoHash]),
	    gen_tcp:close(Socket),
	    ok
    end.

inform_peer_master(Socket, Pid, ReservedBytes, PeerId) ->
    case etorrent_t_peer_group:new_incoming_peer(Pid, PeerId) of
	{ok, PeerProcessPid} ->
	    ok = gen_tcp:controlling_process(Socket, PeerProcessPid),
	    % TODO: Pass PeerId here?
	    etorrent_t_peer_recv:complete_handshake(PeerProcessPid,
						 ReservedBytes,
						 Socket),
	    ok;
	bad_peer ->
	    error_logger:info_report([peer_id_is_bad, PeerId]),
	    gen_tcp:close(Socket),
	    ok
    end.
