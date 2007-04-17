%%%-------------------------------------------------------------------
%%% File    : torrent_peer_send.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus>
%%% Description : Send out events to a foreign socket.
%%%
%%% Created : 27 Jan 2007 by Jesper Louis Andersen <jlouis@succubus>
%%%-------------------------------------------------------------------
-module(torrent_peer_send).

-behaviour(gen_server).

%% API
-export([start_link/4, send_choke/1, send_unchoke/1, send_interested/1,
	 send_request/2, send_bitfield/3, send_not_interested/1,
	 send_piece/5, send_request/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {socket = none,
	        master_pid = none}).

-define(DEFAULT_KEEP_ALIVE_INTERVAL, 120*1000).

%%====================================================================
%% API
%%====================================================================
start_link(Socket, MasterPid, PeerId, InfoHash) ->
    gen_server:start_link(?MODULE,
			  [Socket, MasterPid, PeerId, InfoHash], []).

send_interested(Pid) ->
    send_datagram(Pid, interested).

send_not_interested(Pid) ->
    send_datagram(Pid, not_interested).

send_piece(Pid, Index, Begin, Len, Data) ->
    send_reply_datagram(Pid, {piece, Index, Begin, Len, Data}).

send_request(Pid, Index, Begin, Len) ->
    send_datagram(Pid, {request, Index, Begin, Len}).

send_bitfield(Pid, PiecesWeHave, TotalPieces) ->
    NumberOfPieces = sets:size(PiecesWeHave),
    if
	NumberOfPieces > 0 ->
	    send_datagram(Pid,
			 {bitfield,
			  peer_communication:construct_bitfield(
			    TotalPieces,
			    PiecesWeHave)}),
	    ok;
	true ->
	    ok
    end.

send_choke(Pid) ->
    send_datagram(Pid, choke).

send_unchoke(Pid) ->
    send_datagram(Pid, unchoke).


send_datagram(Pid, Datagram) ->
    gen_server:cast(Pid, {send_datagram, Datagram}).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Socket, MasterPid, PeerId, InfoHash]) ->
    peer_communication:send_handshake(Socket, PeerId, InfoHash),
    {ok,
     #state{socket = Socket,
	    master_pid = MasterPid},
     ?DEFAULT_KEEP_ALIVE_INTERVAL}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast({send_datagram, Message}, S) ->
    ok = peer_communication:send_message(S#state.socket,
					 Message),
    {noreply, S};
handle_cast({send_reply_datagram, Message}, S) ->
    ok = peer_communication:send_message(S#state.socket,
					 Message),
    gen_server:cast(S#state.master_pid, datagram_sent),
    {noreply, S};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(timeout, S) ->
    ok = peer_communication:send_message(S#state.socket, keep_alive),
    {noreply, S};
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
send_request(State, {Index, Begin, Len}) ->
    send_datagram(State, {request, {Index, Begin, Len}}).

send_reply_datagram(Pid, Datagram) ->
    gen_server:cast(Pid, {send_reply_datagram, Datagram}).

