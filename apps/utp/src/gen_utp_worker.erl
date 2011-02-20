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
-export([connect/1, accept/2, close/1]).

%% Internal API
-export([incoming/2]).

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
%% Default extensions to use when SYN/SYNACK'ing
-define(SYN_EXTS, [{ext_bits, <<0:64/integer>>}]).

-type ip_address() :: {byte(), byte(), byte(), byte()}.
-record(sock_info, { addr :: string() | ip_address(),
		     port :: 0..16#FFFF,
		     socket :: gen_udp:socket(),
		     opts :: proplists:proplist() }).

-record(state_idle, { sock_info :: #sock_info{} }).
-record(state_syn_sent, { sock_info    :: #sock_info{},
			  conn_id_send :: integer(),
			  seq_no       :: integer(), % @todo probably need more here
					          % Push into #conn{} state
			  connector    :: {reference(), pid()} }).

-record(state_connected, { sock_info    :: #sock_info{},
			   conn_id_send :: integer(),
			   seq_no       :: integer(),
			   ack_no       :: integer() }).

%%%===================================================================

%% @doc Create a worker for a peer endpoint
%% @end
start_link(Socket, Addr, Port, Options) ->
    gen_fsm:start_link({local, ?SERVER}, ?MODULE, [Socket, Addr, Port, Options], []).

%% @doc Send a connect event
%% @end
connect(Pid) ->
    gen_fsm:sync_send_event(Pid, connect). % @todo Timeouting!

%% @doc Send an accept event
%% @end
accept(Pid, SynPacket) ->
    gen_fsm:sync_send_event(Pid, {accept, SynPacket}). % @todo Timeouting!

%% @doc Send a close event
%% @end
close(Pid) ->
    %% Consider making it sync, but the de-facto implementation isn't
    gen_fsm:send_event(Pid, close).

%% ----------------------------------------------------------------------
incoming(Pid, Packet) ->
    gen_fsm:send_event(Pid, Packet).

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
idle(close, S) ->
    {next_state, destroy, S};
idle(Msg, S) ->
    %% Ignore messages
    error_logger:warning_report([async_message, idle, Msg]),
    {next_state, idle, S}.

%% @private
syn_sent(#packet { ty = st_state,
		   seq_no = PktSeqNo },
	 #state_syn_sent { sock_info = SockInfo,
			   conn_id_send = Conn_id_send,
			   seq_no = SeqNo,
			   connector = From
			 }) ->
    gen_fsm:reply(From, ok),
    {next_state, connected, #state_connected { sock_info = SockInfo,
					       conn_id_send = Conn_id_send,
					       seq_no = SeqNo,
					       ack_no = PktSeqNo }};
syn_sent(close, _S) ->
    todo_alter_rto;
syn_sent(Msg, S) ->
    %% Ignore messages
    error_logger:warning_report([async_message, syn_sent, Msg]),
    {next_state, syn_sent, S}.

%% @private
connected(close, #state_connected { sock_info = SockInfo } = S) ->
    %% Close down connection!
    ok = send_fin(SockInfo),
    {next_state, fin_sent, S};
connected(Msg, S) ->
    %% Ignore messages
    error_logger:warning_report([async_message, connected, Msg]),
    {next_state, connected, S}.

%% @private
connected_full(close, #state_connected { sock_info = SockInfo } = S) ->
    %% Close down connection!
    ok = send_fin(SockInfo),
    {next_state, fin_sent, S};
connected_full(Msg, S) ->
    %% Ignore messages
    error_logger:warning_report([async_message, connected_full, Msg]),
    {next_state, connected_full, S}.

%% @private
got_fin(close, S) ->
    {next_state, destroy_delay, S};
got_fin(Msg, S) ->
    %% Ignore messages
    error_logger:warning_report([async_message, got_fin, Msg]),
    {next_state, got_fin, S}.

%% @private
%% Die deliberately on close for now
destroy_delay(Msg, S) ->
    %% Ignore messages
    error_logger:warning_report([async_message, destroy_delay, Msg]),
    {next_state, destroy_delay, S}.

%% @private
%% Die deliberately on close for now
fin_sent(Msg, S) ->
    %% Ignore messages
    error_logger:warning_report([async_message, fin_sent, Msg]),
    {next_state, fin_sent, S}.

%% @private
reset(close, S) ->
    {next_state, destroy, S};
reset(Msg, S) ->
    %% Ignore messages
    error_logger:warning_report([async_message, reset, Msg]),
    {next_state, reset, S}.

%% @private
%% Die deliberately on close for now
destroy(Msg, S) ->
    %% Ignore messages
    error_logger:warning_report([async_message, destroy, Msg]),
    {next_state, destroy, S}.


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
    gen_utp:register_process(self(), Conn_id_recv),

    Conn_id_send = Conn_id_recv + 1,
    SynPacket = #packet { ty = st_syn,
			  seq_no = 1,
			  ack_no = 0,
			  conn_id = Conn_id_recv,
			  extension = ?SYN_EXTS
			}, % Rest are defaults
    ok = send(SockInfo, SynPacket),
    {next_state, syn_sent, #state_syn_sent { sock_info = SockInfo,
					     seq_no = 2,
					     conn_id_send = Conn_id_send,
					     connector = From }};
idle({accept, SYN}, _From, #state_idle { sock_info = SockInfo }) ->
    Conn_id_recv = SYN#packet.conn_id + 1,
    gen_utp:register_process(self(), Conn_id_recv),

    Conn_id_send = SYN#packet.conn_id,
    SeqNo = mk_random_seq_no(),
    AckNo = SYN#packet.ack_no,
    AckPacket = #packet { ty = st_state,
			  seq_no = SeqNo, % @todo meaning of ++ ?
			  ack_no = AckNo,
			  conn_id = Conn_id_send,
			  extension = ?SYN_EXTS
			},
    ok = send(SockInfo, AckPacket),
    {reply, ok, connected, #state_connected { sock_info = SockInfo,
					      seq_no = SeqNo + 1,
					      ack_no = AckNo,
					      conn_id_send = Conn_id_send }};
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

%% @private
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

%% @private
terminate(_Reason, _StateName, _State) ->
    ok.

%% @private
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================

mk_random_seq_no() ->
    <<N:16/integer>> = crypto:random_bytes(2),
    N.

send_fin(_SockInfo) ->
    todo.

send(#sock_info { socket = Socket,
		  addr = Addr, port = Port }, Packet) ->
    %% @todo Handle timestamping here!!
    gen_udp:send_packet(Socket, Addr, Port, utp_proto:encode(Packet, 0,0)).
