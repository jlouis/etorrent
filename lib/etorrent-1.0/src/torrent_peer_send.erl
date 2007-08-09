%%%-------------------------------------------------------------------
%%% File    : torrent_peer_send.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus>
%%% License : See COPYING
%%% Description : Send out events to a foreign socket.
%%%
%%% Created : 27 Jan 2007 by Jesper Louis Andersen <jlouis@succubus>
%%%-------------------------------------------------------------------
-module(torrent_peer_send).

-behaviour(gen_fsm).

%% API
-export([start_link/4, send/2, remote_request/4, cancel/4, choke/1, unchoke/1,
	 local_request/4, not_interested/1, send_have_piece/2]).

%% gen_server callbacks
-export([init/1, handle_info/3, terminate/3, code_change/4,
	 running/2, keep_alive/2, handle_event/3, handle_sync_event/4]).

-record(state, {socket = none,
	        request_queue = none,

		choke = true,

	        piece_cache = none,
		master_pid = none,
		state_pid = none,
	        file_system_pid = none}).

-define(DEFAULT_KEEP_ALIVE_INTERVAL, 120*1000). % From proto. spec.
-define(MAX_REQUESTS, 1024). % Maximal number of requests a peer may make.
%%====================================================================
%% API
%%====================================================================
start_link(Socket, FilesystemPid, StatePid, MasterPid) ->
    gen_fsm:start_link(?MODULE,
			  [Socket, FilesystemPid, StatePid, MasterPid], []).

send(Pid, Msg) ->
    gen_fsm:send_event(Pid, {send, Msg}).

remote_request(Pid, Index, Offset, Len) ->
    gen_fsm:send_event(Pid, {remote_request_piece, Index, Offset, Len}).

local_request(Pid, Index, Offset, Len) ->
    gen_fsm:send_event(Pid, {local_request_piece, Index, Offset, Len}).

cancel(Pid, Index, Offset, Len) ->
    gen_fsm:send_event(Pid, {cancel_piece, Index, Offset, Len}).

choke(Pid) ->
    gen_fsm:send_event(Pid, choke).

unchoke(Pid) ->
    gen_fsm:send_event(Pid, unchoke).

not_interested(Pid) ->
    gen_fsm:send_event(Pid, not_interested).

send_have_piece(Pid, PieceNumber) ->
    gen_fsm:send_event(Pid, {have, PieceNumber}).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Socket, FilesystemPid, StatePid, MasterPid]) ->
    {ok,
     keep_alive,
     #state{socket = Socket,
	    request_queue = queue:new(),
	    state_pid = StatePid,
	    master_pid = MasterPid,
	    file_system_pid = FilesystemPid},
     ?DEFAULT_KEEP_ALIVE_INTERVAL}.

keep_alive(timeout, S) ->
    case peer_communication:send_message(S#state.socket, keep_alive) of
	ok ->
	    {next_state, keep_alive, S, ?DEFAULT_KEEP_ALIVE_INTERVAL};
	{error, closed} ->
	    {stop, shutdown, S}
    end;
keep_alive(Msg, S) ->
    handle_message(Msg, S).

running(timeout, S) when S#state.choke == true ->
    {next_state, keep_alive, S, ?DEFAULT_KEEP_ALIVE_INTERVAL};
running(timeout, S) when S#state.choke == false ->
    case queue:out(S#state.request_queue) of
	{empty, Q} ->
	    {next_state, keep_alive,
	     S#state{request_queue = Q},
	     ?DEFAULT_KEEP_ALIVE_INTERVAL};
	{{value, {Index, Offset, Len}}, NQ} ->
	    NS = send_piece(Index, Offset, Len, S),
	    torrent_state:uploaded_data(S#state.state_pid, Len),
	    torrent_peer_master:uploaded_data(S#state.master_pid, Len),
	    {next_state, running, NS#state{request_queue = NQ}, 0}
    end;
running(Msg, S) ->
    handle_message(Msg, S).

handle_event(_Evt, St, S) ->
    {next_state, St, S, 0}.

handle_sync_event(_Evt, St, _From, S) ->
    {next_state, St, S, 0}.

handle_message({send, Message}, S) ->
    send_message(Message, S, running, 0);

handle_message(choke, S) when S#state.choke == true ->
    {next_state, running, S};
handle_message(choke, S) when S#state.choke == false ->
    send_message(choke, S#state{choke = true}, running, 0);

handle_message(unchoke, S) when S#state.choke == false ->
    {next_state, running, S};
handle_message(unchoke, S) when S#state.choke == true ->
    send_message(unchoke, S#state{choke = false}, running, 0);
handle_message(not_interested, S) ->
    send_message(not_interested, S, running, 0);
handle_message({have, Pn}, S) ->
    send_message({have, Pn}, S, running, 0);
handle_message({local_request_piece, Index, Offset, Len}, S) ->
    send_message({request, Index, Offset, Len}, S, running, 0);
handle_message({remote_request_piece, Index, Offset, Len}, S) ->
    Requests = queue:len(S#state.request_queue),
    if
	Requests > ?MAX_REQUESTS ->
	    {stop, max_queue_len_exceeded, S};
	true ->
	    NQ = queue:in({Index, Offset, Len}, S#state.request_queue),
	    {next_state, running, S#state{request_queue = NQ}, 0}
    end;
handle_message({cancel_piece, Index, OffSet, Len}, S) ->
    NQ = utils:queue_remove({Index, OffSet, Len}, S#state.request_queue),
    {next_state, running, S#state{request_queue = NQ}, 0}.


handle_info(_Msg, StateName, S) ->
    {next_state, StateName, S}.

terminate(_Reason, _St, _State) ->
    ok.

code_change(_OldVsn, _State, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
send_piece(Index, Offset, Len, S) ->
    case S#state.piece_cache of
	{I, Binary} when I == Index ->
	    <<_Skip:Offset/binary, Data:Len/binary, _R/binary>> = Binary,
	    Msg = {piece, Index, Offset, Data},
	    % TODO: This call may fail.
	    ok = peer_communication:send_message(S#state.socket,
						 Msg),
	    S;
	{I, _Binary} when I /= Index ->
	    NS = load_piece(Index, S),
	    send_piece(Index, Offset, Len, NS);
	none ->
	    NS = load_piece(Index, S),
	    send_piece(Index, Offset, Len, NS)
    end.

load_piece(Index, S) ->
    {ok, Piece} = file_system:read_piece(S#state.file_system_pid, Index),
    S#state{piece_cache = {Index, Piece}}.

send_message(Msg, S, NewState, Timeout) ->
    case peer_communication:send_message(S#state.socket, Msg) of
	ok ->
	    {next_state, NewState, S, Timeout};
	{error, closed} ->
	    {stop, shutdown, S}
    end.

