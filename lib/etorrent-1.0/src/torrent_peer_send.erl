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
-export([start_link/1, send/2, send_sync/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {socket = none}).

-define(DEFAULT_KEEP_ALIVE_INTERVAL, 120*1000).

%%====================================================================
%% API
%%====================================================================
start_link(Socket) ->
    gen_server:start_link(?MODULE,
			  [Socket], []).

send(Pid, Msg) ->
    gen_server:cast(Pid, {send, Msg}).

send_sync(Pid, Msg) ->
    gen_server:call(Pid, {send, Msg}).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Socket]) ->
    {ok,
     #state{socket = Socket},
     ?DEFAULT_KEEP_ALIVE_INTERVAL}.

handle_call({send, Message}, _From, S) ->
    ok = peer_communication:send_message(S#state.socket,
					 Message),
    {reply, ok, S, ?DEFAULT_KEEP_ALIVE_INTERVAL};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State, ?DEFAULT_KEEP_ALIVE_INTERVAL}.

handle_cast({send, Message}, S) ->
    ok = peer_communication:send_message(S#state.socket,
					 Message),
    {noreply, S, ?DEFAULT_KEEP_ALIVE_INTERVAL};
handle_cast(_Msg, State) ->
    {noreply, State, ?DEFAULT_KEEP_ALIVE_INTERVAL}.

handle_info(timeout, S) ->
    ok = peer_communication:send_message(S#state.socket, keep_alive),
    {noreply, S, ?DEFAULT_KEEP_ALIVE_INTERVAL};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

