%%%-------------------------------------------------------------------
%%% @author Jesper Louis andersen <jesper.louis.andersen@gmail.com>
%%% @copyright (C) 2011, Jesper Louis andersen
%%% @doc
%%%
%%% @end
%%% Created : 19 Feb 2011 by Jesper Louis andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(gen_utp_worker).

-include("utp.hrl").

-behaviour(gen_fsm).

%% API
-export([start_link/4]).

%% Operations
-export([connect/1]).

%% gen_fsm callbacks
-export([init/1, handle_event/3,
	 handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

%% gen_fsm callback states
-export([idle/2, idle/3,
	 syn_sent/2,
	 connected/2,
	 connected_full/2,
	 got_fin/2,
	 destroy_delay/2,
	 fin_sent/2,
	 reset/2,
	 destroy/2]).

-type conn_st() :: idle | syn_sent | connected | connected_full | got_fin
		   | destroy_delay | fin_sent | reset | destroy.

-export_type([conn_st/0]).

-define(SERVER, ?MODULE).

-type ip_address() :: {byte(), byte(), byte(), byte()}.
-record(sock_info, { addr :: string() | ip_address(),
		     port :: 0..16#FFFF,
		     socket :: gen_udp:socket(),
		     opts :: proplists:proplist() }).

-record(state_idle, { sock_info :: #sock_info{} }).
-record(state_syn_sent, { sock_info :: #sock_info{},
			  conn_id_send :: integer(),
			  seq_no    :: integer(), % @todo probably need more here
					          % Push into #conn{} state
			  connector :: {reference(), pid()} }).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Create a worker for a peer endpoint
%% @end
start_link(Socket, Addr, Port, Options) ->
    gen_fsm:start_link({local, ?SERVER}, ?MODULE, [Socket, Addr, Port, Options], []).

connect(Pid) ->
    gen_fsm:sync_send_event(Pid, connect). % @todo Timeouting!

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/[3,4], this function is called by the new
%% process to initialize.
%%
%% @spec init(Args) -> {ok, StateName, State} |
%%                     {ok, StateName, State, Timeout} |
%%                     ignore |
%%                     {stop, StopReason}
%% @end
%%--------------------------------------------------------------------
init([Addr, Port, Options]) ->
    SockInfo = #sock_info { addr = Addr,
			    port = Port,
			    opts = Options },
    {ok, state_name, #state_idle{ sock_info = SockInfo }}.

%% @private
idle(Msg, S) ->
    %% Ignore messages
    error_logger:warning_report([async_message, idle, Msg]),
    {next_state, idle, S}.

%% @private
syn_sent(_Msg, _State) ->
    todo.

%% @private
connected(_Msg, _State) ->
    todo.

%% @private
connected_full(_Msg, _State) ->
    todo.

%% @private
got_fin(_Msg, _State) ->
    todo.

%% @private
destroy_delay(_Msg, _State) ->
    todo.

%% @private
fin_sent(_Msg, _State) ->
    todo.

%% @private
reset(_Msg, _State) ->
    todo.

%% @private
destroy(_Msg, _State) ->
    todo.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% There should be one instance of this function for each possible
%% state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_event/[2,3], the instance of this function with
%% the same name as the current state name StateName is called to
%% handle the event.
%%
%% @spec state_name(Event, From, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {reply, Reply, NextStateName, NextState} |
%%                   {reply, Reply, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState} |
%%                   {stop, Reason, Reply, NewState}
%% @end
%%--------------------------------------------------------------------
idle(connect, From, #state_idle { sock_info = SockInfo }) ->
    Conn_id_recv = utp_proto:mk_connection_id(),
    Conn_id_send = Conn_id_recv + 1,
    SynPacket = #packet { ty = st_syn,
			  seq_no = 1,
			  ack_no = 0,
			  conn_id = Conn_id_recv
			}, % Rest are defaults
    ok = send(SockInfo, SynPacket),
    {next_state, syn_sent, #state_syn_sent { sock_info = SockInfo,
					     seq_no = 2,
					     conn_id_send = Conn_id_send,
					     connector = From }};
idle(_Msg, _From, S) ->
    {reply, idle, {error, enotconn}, S}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%
%% @spec handle_event(Event, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/[2,3], this function is called
%% to handle the event.
%%
%% @spec handle_sync_event(Event, From, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {reply, Reply, NextStateName, NextState} |
%%                   {reply, Reply, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState} |
%%                   {stop, Reason, Reply, NewState}
%% @end
%%--------------------------------------------------------------------
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it receives any
%% message other than a synchronous or asynchronous event
%% (or a system message).
%%
%% @spec handle_info(Info,StateName,State)->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%
%% @spec terminate(Reason, StateName, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _StateName, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, StateName, State, Extra) ->
%%                   {ok, StateName, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================

send(#sock_info { socket = Socket,
		  addr = Addr, port = Port }, Packet) ->
    %% @todo Handle timestamping here!!
    gen_udp:send_packet(Socket, Addr, Port, utp_proto:encode(Packet, 0,0)).
