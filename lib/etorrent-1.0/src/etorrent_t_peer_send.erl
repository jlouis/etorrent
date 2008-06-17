%%%-------------------------------------------------------------------
%%% File    : etorrent_t_peer_send.erl
%%% Author  : Jesper Louis Andersen
%%% License : See COPYING
%%% Description : Send out events to a foreign socket.
%%%
%%% Created : 27 Jan 2007 by
%%%   Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_t_peer_send).

-behaviour(gen_server).

%% API
-export([start_link/3, remote_request/4, cancel/4, choke/1, unchoke/1,
	 local_request/4, not_interested/1, send_have_piece/2, stop/1,
	 bitfield/2, interested/1]).

%% gen_server callbacks
-export([init/1, handle_info/2, terminate/2, code_change/3,
	 handle_call/3, handle_cast/2]).

-record(state, {socket = none,
	        request_queue = none,

		choke = true,
		timer = none,
		parent = none,
	        piece_cache = none,
		torrent_id = none,
	        file_system_pid = none}).

-define(DEFAULT_KEEP_ALIVE_INTERVAL, 120*1000). % From proto. spec.
-define(MAX_REQUESTS, 1024). % Maximal number of requests a peer may make.
%%====================================================================
%% API
%%====================================================================
start_link(Socket, FilesystemPid, TorrentId) ->
    gen_server:start_link(?MODULE,
			  [Socket, FilesystemPid, TorrentId, self()], []).

%%--------------------------------------------------------------------
%% Func: remote_request(Pid, Index, Offset, Len)
%% Description: The remote end (ie, the peer) requested a chunk
%%  {Index, Offset, Len}
%%--------------------------------------------------------------------
remote_request(Pid, Index, Offset, Len) ->
    gen_server:cast(Pid, {remote_request_piece, Index, Offset, Len}).

%%--------------------------------------------------------------------
%% Func: local_request(Pid, Index, Offset, Len)
%% Description: We request a piece from the peer: {Index, Offset, Len}
%%--------------------------------------------------------------------
local_request(Pid, Index, Offset, Len) ->
    gen_server:cast(Pid, {local_request_piece, Index, Offset, Len}).

%%--------------------------------------------------------------------
%% Func: cancel(Pid, Index, Offset, Len)
%% Description: Cancel the {Index, Offset, Len} at the peer.
%%--------------------------------------------------------------------
cancel(Pid, Index, Offset, Len) ->
    gen_server:cast(Pid, {cancel_piece, Index, Offset, Len}).

%%--------------------------------------------------------------------
%% Func: choke(Pid)
%% Description: Choke the peer.
%%--------------------------------------------------------------------
choke(Pid) ->
    gen_server:cast(Pid, choke).

%%--------------------------------------------------------------------
%% Func: unchoke(Pid)
%% Description: Unchoke the peer.
%%--------------------------------------------------------------------
unchoke(Pid) ->
    gen_server:cast(Pid, unchoke).

%%--------------------------------------------------------------------
%% Func: not_interested(Pid)
%% Description: Tell the peer we are not interested in him anymore
%%--------------------------------------------------------------------
not_interested(Pid) ->
    gen_server:cast(Pid, not_interested).

interested(Pid) ->
    gen_server:cast(Pid, interested).

%%--------------------------------------------------------------------
%% Func: send_have_piece(Pid, PieceNumber)
%% Description: Tell the peer we have the piece PieceNumber
%%--------------------------------------------------------------------
send_have_piece(Pid, PieceNumber) ->
    gen_server:cast(Pid, {have, PieceNumber}).

bitfield(Pid, BitField) ->
    gen_server:cast(Pid, {bitfield, BitField}).


%%--------------------------------------------------------------------
%% Func: stop(Pid)
%% Description: Tell the send process to stop the communication.
%%--------------------------------------------------------------------
stop(Pid) ->
    gen_server:cast(Pid, stop).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Socket, FilesystemPid, TorrentId, Parent]) ->
    {ok,
     #state{socket = Socket,
	    request_queue = queue:new(),
	    parent = Parent,
	    torrent_id = TorrentId,
	    file_system_pid = FilesystemPid},
     0}.

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
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_info(keep_alive_tick, S) ->
    %% Special case. Set the timer and call send_message with a Timout so it avoids
    %% a timer cancel.
    {ok, TRef} = timer:send_after(?DEFAULT_KEEP_ALIVE_INTERVAL, self(), keep_alive_tick),
    send_message(keep_alive, S#state { timer = TRef} , 0);
handle_info(timeout, S) when S#state.choke =:= true ->
    set_timer(S);
handle_info(timeout, S) when S#state.choke =:= false ->
    case queue:out(S#state.request_queue) of
	{empty, _} ->
	    set_timer(S);
	{{value, {Index, Offset, Len}}, NewQ} ->
	    send_piece(Index, Offset, Len, S#state { request_queue = NewQ } )
    end;
handle_info(Msg, S) ->
    error_logger:info_report([got_unknown_message, Msg, S]),
    {stop, {unknown_msg, Msg}}.


handle_cast(choke, S) when S#state.choke == true ->
    {noreply, S, 0};
handle_cast(choke, S) when S#state.choke == false ->
    send_message(choke, S#state{choke = true});
handle_cast(unchoke, S) when S#state.choke == false ->
    {noreply, S, 0};
handle_cast(unchoke, S) when S#state.choke == true ->
    send_message(unchoke, S#state{choke = false,
				  request_queue = queue:new()});
handle_cast({bitfield, BF}, S) ->
    send_message({bitfield, BF}, S);
handle_cast(not_interested, S) ->
    send_message(not_interested, S);
handle_cast(interested, S) ->
    send_message(interested, S);
handle_cast({have, Pn}, S) ->
    send_message({have, Pn}, S);
handle_cast({local_request_piece, Index, Offset, Len}, S) ->
    send_message({request, Index, Offset, Len}, S);
handle_cast({remote_request_piece, _Index, _Offset, _Len}, S)
  when S#state.choke == true ->
    {noreply, S, 0};
handle_cast(stop, S) ->
    {stop, normal, S};
handle_cast({remote_request_piece, Index, Offset, Len}, S)
  when S#state.choke == false ->
    Requests = queue:len(S#state.request_queue),
    case Requests > ?MAX_REQUESTS of
	true ->
	    {stop, max_queue_len_exceeded, S};
	false ->
	    NQ = queue:in({Index, Offset, Len}, S#state.request_queue),
	    {noreply, S#state{request_queue = NQ}, 0}
    end;
handle_cast({cancel_piece, Index, OffSet, Len}, S) ->
    NQ = etorrent_utils:queue_remove({Index, OffSet, Len}, S#state.request_queue),
    {noreply, S#state{request_queue = NQ}, 0}.


%% Terminating normally means we should inform our recv pair
terminate(normal, S) ->
    etorrent_t_peer_recv:stop(S#state.parent),
    ok;
terminate(Reason, State) ->
    error_logger:info_report([peer_send_terminating, Reason, State]),
    ok.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: send_piece_message/2
%% Description: Send the message Msg and handle an eventual connection
%%   close gracefully.
%%--------------------------------------------------------------------
send_piece_message(Msg, S, Timeout) ->
    case etorrent_peer_communication:send_message(S#state.socket, Msg) of
	ok ->
	    {noreply, S, Timeout};
	{error, closed} ->
	    error_logger:info_report([remote_closed, S#state.torrent_id]),
	    {stop, normal, S}
    end.

send_piece(Index, Offset, Len, S) ->
    case S#state.piece_cache of
	{I, Binary} when I == Index ->
	    <<_Skip:Offset/binary, Data:Len/binary, _R/binary>> = Binary,
	    Msg = {piece, Index, Offset, Data},
	    %% Track uploaded size for torrent (for the tracker)
	    etorrent_torrent:statechange(S#state.torrent_id,
					 {add_upload, Len}),
	    %% Track the amount uploaded by this peer.
	    %% XXX: On slow lines, this won't do at all.
	    etorrent_peer:statechange(S#state.parent, {uploaded, Len}),
	    send_piece_message(Msg, S, 0);
	%% Update cache and try again...
	{I, _Binary} when I /= Index ->
	    NS = load_piece(Index, S),
	    send_piece(Index, Offset, Len, NS);
	none ->
	    NS = load_piece(Index, S),
	    send_piece(Index, Offset, Len, NS)
    end.

load_piece(Index, S) ->
    {ok, Piece} = etorrent_fs:read_piece(S#state.file_system_pid, Index),
    S#state{piece_cache = {Index, Piece}}.

send_message(Msg, S) ->
    case S#state.timer of
	none ->
	    ok;
	TRef ->
	    timer:cancel(TRef)
    end,
    send_message(Msg, S, 0).

send_message(Msg, S, Timeout) ->
    case etorrent_peer_communication:send_message(S#state.socket, Msg) of
	ok ->
	    {noreply, S, Timeout};
	{error, closed} ->
	    error_logger:info_report([remote_closed, S#state.torrent_id]),
	    {stop, normal, S}
    end.

set_timer(S) ->
    case S#state.timer of
	none ->
	    {ok, TRef} = timer:send_after(?DEFAULT_KEEP_ALIVE_INTERVAL, self(), keep_alive_tick),
	    {noreply, S#state { timer = TRef }};
	_ ->
	    {noreply, S}
    end.
