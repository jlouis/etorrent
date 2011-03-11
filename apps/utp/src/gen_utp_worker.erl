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
-export([connect/1,
	 accept/2,
	 close/1,

	 recv/2,
	 send/2
	]).

%% Internal API
-export([
	 incoming/3,
	 reply/2,
	 send_pkt/2
	]).

%% gen_fsm callbacks
-export([init/1, handle_event/3,
	 handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

%% gen_fsm callback states
-export([idle/2, idle/3,
	 syn_sent/2,
	 connected/2, connected/3,
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

%% Default SYN packet timeout
-define(SYN_TIMEOUT, 3000).
-define(RTT_VAR, 800). % Round trip time variance
-define(PACKET_SIZE, 350). % @todo Probably dead!
-define(MAX_WINDOW_USER, 255 * ?PACKET_SIZE). % Likewise!
-define(DEFAULT_ACK_TIME, 16#70000000). % Default add to the future when an Ack is expected
-define(DELAYED_ACK_BYTE_THRESHOLD, 2400). % bytes
-define(DELAYED_ACK_TIME_THRESHOLD, 100).  % milliseconds
-define(KEEPALIVE_INTERVAL, 29000). % ms

%% Number of bytes to increase max window size by, per RTT. This is
%% scaled down linearly proportional to off_target. i.e. if all packets
%% in one window have 0 delay, window size will increase by this number.
%% Typically it's less. TCP increases one MSS per RTT, which is 1500
-define(MAX_CWND_INCREASE_BYTES_PER_RTT, 3000).
-define(CUR_DELAY_SIZE, 3).

%% Experiments suggest that a clock skew of 10 ms per 325 seconds
%% is not impossible. Reset delay_base every 13 minutes. The clock
%% skew is dealt with by observing the delay base in the other
%% direction, and adjusting our own upwards if the opposite direction
%% delay base keeps going down
-define(DELAY_BASE_HISTORY, 13).
-define(MAX_WINDOW_DECAY, 100). % ms

-type ip_address() :: {byte(), byte(), byte(), byte()}.

%% @todo Decide how to split up these records in a nice way.
%% @todo Right now it is just the god record!
-record(sock_info, {
	  %% Stuff pertaining to the socket:
	  addr        :: string() | ip_address(),
	  opts        :: proplists:proplist(), %% Options on the socket
	  packet_size :: integer(),
	  port        :: 0..16#FFFF,
	  socket      :: gen_udp:socket(),
          timestamp_difference :: integer()
	 }).

%% STATE RECORDS
%% ----------------------------------------------------------------------
-record(state, { sock_info    :: #sock_info{},
                 pkt_info     :: utp_pkt:t(),
                 pkt_buf      :: utp_pkt:buf(),
                 proc_info    :: utp_process:t(),
                 conn_id_send :: integer(),
                 seq_no       :: integer(),
                 ack_no       :: integer(),
                 connector    :: {reference(), pid()},
                 syn_timeout  :: reference()
               }).

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

%% @doc Receive some bytes from the socket. Blocks until the said amount of
%% bytes have been read.
%% @end
recv(Pid, Amount) ->
    gen_fsm:sync_send_event(Pid, {recv, Amount}, infinity).

%% @doc Send some bytes from the socket. Blocks until the said amount of
%% bytes have been sent and has been accepted by the underlying layer.
%% @end
send(Pid, Data) ->
    gen_fsm:sync_send_event(Pid, {send, Data}).

%% @doc Send a close event
%% @end
close(Pid) ->
    %% Consider making it sync, but the de-facto implementation isn't
    gen_fsm:send_event(Pid, close).

%% ----------------------------------------------------------------------
incoming(Pid, Packet, Timing) ->
    gen_fsm:send_event(Pid, {pkt, Packet, Timing}).

reply(To, Msg) ->
    gen_fsm:reply(To, Msg).

send_pkt(#sock_info { socket = Socket,
                      addr = Addr,
                      port = Port,
                      timestamp_difference = TSDiff}, Packet) ->
    %% @todo Handle timestamping here!!
    gen_udp:send(Socket, Addr, Port, utp_proto:encode(Packet, TSDiff)).

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
init([Socket, Addr, Port, Options]) ->
    PktInfo  = utp_pkt:mk(),
    SockInfo = #sock_info { addr = Addr,
			    port = Port,
			    opts = Options,
			    socket = Socket,
                            timestamp_difference = 0 % @todo check this value
			  },
    {ok, state_name, #state{ sock_info = SockInfo,
                             pkt_info  = PktInfo }}.

%% @private
idle(close, S) ->
    {next_state, destroy, S};
idle(Msg, S) ->
    %% Ignore messages
    error_logger:warning_report([async_message, idle, Msg]),
    {next_state, idle, S}.

%% @private
syn_sent({pkt, #packet { ty = st_state,
			 seq_no = PktSeqNo },
	       _Timing},
	 #state { sock_info = SockInfo,
                  conn_id_send = Conn_id_send,
                  seq_no = SeqNo,
                  connector = From,
                  syn_timeout = TRef
                }) ->
    gen_fsm:cancel_timer(TRef),
    reply(From, ok),
    {next_state, connected, #state { sock_info = SockInfo,
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
connected({pkt, Pkt, {_TS, _TSDiff, RecvTime}},
	  #state { pkt_info = PKI,
			     pkt_buf  = PB,
			     proc_info = PRI
			     } = S) ->
    case utp_pkt:handle_packet(RecvTime, connected, Pkt, PKI, PB) of
	{ok, N_PB1, N_PKI, StateAlter} ->
	    {N_PRI, N_PB} =
		case satisfy_recvs(PRI, N_PB1) of
		    {ok, PR, PB} -> {PR, PB};
		    {rb_drained, PR, PB} ->
			case utp_pkt:rb_drained(PB) of
			    ok -> ok;
			    send_ack -> todo;
			    ack_timer -> todo
			end,
			{PR, PB}
		end,
	    {next_state, connected,
	     S#state { pkt_info = N_PKI,
				 pkt_buf = N_PB,
				 proc_info = N_PRI }}
    end;
connected(close, #state { sock_info = SockInfo } = State) ->
    %% Close down connection!
    ok = utp_pkt:send_fin(SockInfo),
    {next_state, fin_sent, State};
connected(Msg, State) ->
    %% Ignore messages
    error_logger:warning_report([async_message, connected, Msg]),
    {next_state, connected, State}.

%% @private
connected_full(close, #state { sock_info = SockInfo } = State) ->
    %% Close down connection!
    ok = utp_pkt:send_fin(SockInfo),
    {next_state, fin_sent, State};
connected_full(Msg, State) ->
    %% Ignore messages
    error_logger:warning_report([async_message, connected_full, Msg]),
    {next_state, connected_full, State}.

%% @private
got_fin(close, State) ->
    {next_state, destroy_delay, State};
got_fin(Msg, State) ->
    %% Ignore messages
    error_logger:warning_report([async_message, got_fin, Msg]),
    {next_state, got_fin, State}.

%% @private
%% Die deliberately on close for now
destroy_delay(Msg, State) ->
    %% Ignore messages
    error_logger:warning_report([async_message, destroy_delay, Msg]),
    {next_state, destroy_delay, State}.

%% @private
%% Die deliberately on close for now
fin_sent(Msg, State) ->
    %% Ignore messages
    error_logger:warning_report([async_message, fin_sent, Msg]),
    {next_state, fin_sent, State}.

%% @private
reset(close, State) ->
    {next_state, destroy, State};
reset(Msg, State) ->
    %% Ignore messages
    error_logger:warning_report([async_message, reset, Msg]),
    {next_state, reset, State}.

%% @private
%% Die deliberately on close for now
destroy(Msg, State) ->
    %% Ignore messages
    error_logger:warning_report([async_message, destroy, Msg]),
    {next_state, destroy, State}.


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
idle(connect, From, State = #state { sock_info = SockInfo }) ->
    TRef = gen_fsm:send_after(?SYN_TIMEOUT, syn_timeout),
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
    {next_state, syn_sent, State#state {
                             syn_timeout = TRef,
                             seq_no = 2, % @todo pkt_buf stuff :/
                             conn_id_send = Conn_id_send, %@todo Where does this belong?
                             connector = From }};
idle({accept, SYN}, _From, #state { sock_info = SockInfo }) ->
    %% @todo timeout handling from the syn packet!
    Conn_id_recv = SYN#packet.conn_id + 1,
    gen_utp:register_process(self(), Conn_id_recv),

    Conn_id_send = SYN#packet.conn_id,
    SeqNo = utp_pkt:mk_random_seq_no(),
    AckNo = SYN#packet.ack_no,
    AckPacket = #packet { ty = st_state,
			  seq_no = SeqNo, % @todo meaning of ++ ?
			  ack_no = AckNo,
			  conn_id = Conn_id_send,
			  extension = ?SYN_EXTS
			},
    ok = send(SockInfo, AckPacket),
    {reply, ok, connected, #state { sock_info = SockInfo,
					      seq_no = SeqNo + 1,
					      ack_no = AckNo,
					      conn_id_send = Conn_id_send }};
idle(_Msg, _From, State) ->
    {reply, idle, {error, enotconn}, State}.

connected({recv, Length}, From, #state { proc_info = PI } = State) ->
    %% @todo Try to satisfy receivers
    {next_state, connected, State#state {
			   proc_info = utp_process:enqueue_receiver(From, Length, PI) }};
connected({send, Data}, From, #state {
			  conn_id_send = ConnId,
			  proc_info = PI,
			  sock_info = SockInfo,
			  pkt_info  = PKI,
			  pkt_buf   = PKB } = State) ->
    ProcInfo = utp_process:enqueue_sender(From, Data, PI),
    {ok, PKB1, ProcInfo1} = utp_pkt:fill_window(ConnId,
						SockInfo,
						ProcInfo,
						PKI,
						PKB),
    {next_state, connected, State#state {
			      proc_info = ProcInfo1,
			      pkt_buf   = PKB1 }};
connected(Msg, From, State) ->
    error_logger:warning_report([sync_message, connected, Msg, From]),
    {next_state, connected, State}.



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
handle_event({timeout, TRef, zerowindow_timeout},
	     SN, #state {
	      pkt_info = PKI
	      } = State)
  when SN == syn_sent; SN == connected; SN == connected_full; SN == fin_sent ->
    PKI1 = utp_pkt:zerowindow_timeout(TRef, PKI),
    {next_state, SN, State#state { pkt_info = PKI1 }};
handle_event({timeout, _TRef, zerowindow_timeout}, SN, State) ->
    {next_state, SN, State}; % Ignore, stray zerowindow timeout
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

satisfy_buffer(From, 0, Res, Buffer) ->
    reply(From, {ok, Res}),
    {ok, Buffer};
satisfy_buffer(From, Length, Res, Buffer) ->
    case utp_pkt:buffer_dequeue(Buffer) of
	{ok, Bin, N_Buffer} when byte_size(Bin) =< Length ->
	    satisfy_buffer(From, Length - byte_size(Bin), <<Res/binary, Bin/binary>>, N_Buffer);
	{ok, Bin, N_Buffer} when byte_size(Bin) > Length ->
	    <<Cut:Length/binary, Rest/binary>> = Bin,
	    satisfy_buffer(From, 0, <<Res/binary, Cut/binary>>,
			   utp_pkt:buffer_putback(Rest, N_Buffer));
	empty ->
	    {rb_drained, From, Length, Res, Buffer}
    end.

satisfy_recvs(Processes, Buffer) ->
    case utp_process:dequeue_receiver(Processes) of
	{ok, {receiver, Length, From, Res}, N_Processes} ->
	    case satisfy_buffer(From, Length, Res, Buffer) of
		{ok, N_Buffer} ->
		    satisfy_recvs(N_Processes, N_Buffer);
		{rb_drained, F, L, R, N_Buffer} ->
		    {rb_drained, utp_process:putback_receiver(F, L, R, N_Processes), N_Buffer}
	    end;
	empty ->
	    {ok, Processes, Buffer}
    end.





