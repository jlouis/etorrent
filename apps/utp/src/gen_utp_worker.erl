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
	 reply/2
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

-define(DEFAULT_OPT_RECV_SZ, 8192). %% @todo Fix this
-define(DEFAULT_PACKET_SIZE, 350). %% @todo Fix, arbitrary at the moment

%% STATE RECORDS
%% ----------------------------------------------------------------------
-record(state, { sock_info    :: utp_sock_info:t(),
                 pkt_window   :: utp_pkt:t(),
                 pkt_buf      :: utp_pkt:buf(),
                 proc_info    :: utp_process:t(),
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
    PktWindow  = utp_pkt:mk(),
    PktBuf   = utp_pkt:mk_buf(?DEFAULT_OPT_RECV_SZ),
    ProcInfo = utp_process:mk(),
    SockInfo = utp_socket:mk(Addr, Options, ?DEFAULT_PACKET_SIZE, Port, Socket),
    {ok, idle, #state{ sock_info = SockInfo,
                       pkt_buf   = PktBuf,
                       proc_info = ProcInfo,
                       pkt_window  = PktWindow }}.

%% @private
idle(close, S) ->
    {next_state, destroy, S};
idle(Msg, S) ->
    %% Ignore messages
    error_logger:warning_report([async_message, idle, Msg]),
    {next_state, idle, S}.

%% @private
syn_sent({pkt, #packet { ty = st_state,
                         win_sz = WindowSize,
			 seq_no = PktSeqNo },
	       _Timing},
	 #state { sock_info = SockInfo,
                  pkt_buf = PktBuf,
                  pkt_window = PktWin,
                  connector = From,
                  syn_timeout = TRef
                } = State) ->
    gen_fsm:cancel_timer(TRef),
    reply(From, ok),
    {next_state, connected,
     State#state { sock_info = SockInfo,
                   pkt_window = utp_pkt:handle_advertised_window(WindowSize,
                                                                 PktWin),
                   syn_timeout = undefined,
                   pkt_buf = utp_pkt:init_ackno(PktBuf, PktSeqNo)}};
syn_sent(close, _S) ->
    todo_alter_rto;
syn_sent(Msg, S) ->
    %% Ignore messages
    error_logger:warning_report([async_message, syn_sent, Msg]),
    {next_state, syn_sent, S}.


%% @private
connected({pkt, Pkt, {_TS, _TSDiff, RecvTime}},
	  #state { pkt_window = PKI,
                   pkt_buf  = PB,
                   proc_info = PRI,
                   sock_info = SockInfo
                 } = State) ->
    %% @todo I think most of this code path is wrong at the moment
    error_logger:info_report([incoming_pkt, utp_socket:format_pkt(Pkt)]),
    case utp_pkt:handle_packet(RecvTime, connected, Pkt, PKI, PB) of
	{ok, N_PB1, N_PKI, Messages} ->
            utp_pkt:handle_send_ack(SockInfo, N_PB1, Messages),
            N_PKI1 = utp_pkt:handle_advertised_window(Pkt, N_PKI),
	    {N_PRI, N_PB} =
		case satisfy_recvs(PRI, N_PB1) of
		    {ok, PR1, PB1} ->
                        {PR1, PB1};
		    {rb_drained, PR1, PB1} ->
                        %% @todo Here is the point where we should
                        %% make a check on the receive window If the
                        %% window has grown, and the last window was
                        %% 0, then immediately send out an
                        %% ACK. Otherwise install a timer.
                        {PR1, PB1}
		end,
	    {next_state, connected,
	     State#state { pkt_window = N_PKI1,
                           pkt_buf = N_PB,
                           proc_info = N_PRI }}
    end;
connected(close, #state { sock_info = SockInfo,
                          pkt_buf = PktBuf } = State) ->
    %% Close down connection!
    ok = utp_pkt:send_fin(SockInfo, PktBuf),
    {next_state, fin_sent, State};
connected(Msg, State) ->
    %% Ignore messages
    error_logger:warning_report([async_message, connected, Msg]),
    {next_state, connected, State}.

%% @private
connected_full(close, #state { sock_info = SockInfo,
                               pkt_buf   = PktBuf } = State) ->
    %% Close down connection!
    ok = utp_pkt:send_fin(SockInfo, PktBuf),
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
destroy_delay(close, State) ->
    gen_fsm:start_timer(400, destroy),
    {next_state, destroy, State};
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
destroy(destroy, State) ->
    {stop, normal, State};
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
idle(connect, From, State = #state { sock_info = SockInfo,
                                     pkt_buf   = PktBuf}) ->

    TRef = gen_fsm:start_timer(?SYN_TIMEOUT, syn_timeout),
    Conn_id_recv = utp_proto:mk_connection_id(),
    gen_utp:register_process(self(), Conn_id_recv),

    ConnIdSend = Conn_id_recv + 1,
    N_SockInfo = utp_socket:set_conn_id(ConnIdSend, SockInfo),

    SynPacket = #packet { ty = st_syn,
			  seq_no = 1,
			  ack_no = 0,
			  extension = ?SYN_EXTS
			}, % Rest are defaults
    Win = utp_pkt:advertised_window(PktBuf),
    ok = utp_socket:send_pkt(Win, N_SockInfo, SynPacket, Conn_id_recv),
    {next_state, syn_sent, State#state {
                             sock_info = N_SockInfo,
                             syn_timeout = TRef,
                             pkt_buf     = utp_pkt:init_seqno(PktBuf, 2),
                             connector = From }};
idle({accept, SYN}, _From, #state { sock_info = SockInfo,
                                    pkt_window = PktWin,
                                    pkt_buf   = PktBuf } = State) ->
    %% @todo timeout handling from the syn packet!
    Conn_id_recv = SYN#packet.conn_id + 1,
    gen_utp:register_process(self(), Conn_id_recv),

    Conn_id_send = SYN#packet.conn_id,
    N_SockInfo = utp_socket:set_conn_id(Conn_id_send, SockInfo),

    SeqNo = utp_pkt:mk_random_seq_no(),
    AckNo = SYN#packet.seq_no,
    1 = AckNo,

    AckPacket = #packet { ty = st_state,
			  seq_no = SeqNo,
			  ack_no = AckNo,
			  extension = ?SYN_EXTS
			},
    Win = utp_pkt:advertised_window(PktBuf),
    ok = utp_socket:send_pkt(Win, N_SockInfo, AckPacket),
    {reply, ok, connected,
            State#state { sock_info = N_SockInfo,
                          pkt_window = utp_pkt:handle_advertised_window(SYN, PktWin),
                          pkt_buf = utp_pkt:init_ackno(
                                      utp_pkt:init_seqno(PktBuf, SeqNo + 1), AckNo+1)}};

idle(_Msg, _From, State) ->
    {reply, idle, {error, enotconn}, State}.

connected({recv, Length}, From, #state { proc_info = PI,
                                         pkt_buf   = PKB } = State) ->
    %% @todo Try to satisfy receivers
    PI1 = utp_process:enqueue_receiver(From, Length, PI),
    case satisfy_recvs(PI1, PKB) of
        {_, N_PRI, N_PKB} ->
            {next_state, connected,
             State#state {
               proc_info = N_PRI,
               pkt_buf   = N_PKB } }
    end;
connected({send, Data}, From, #state {
                          sock_info = SockInfo,
			  proc_info = PI,
			  pkt_window  = PKI,
			  pkt_buf   = PKB } = State) ->
    ProcInfo = utp_process:enqueue_sender(From, Data, PI),
    {ok, PKB1, ProcInfo1} = utp_pkt:fill_window(SockInfo,
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
	      pkt_window = PKI
	      } = State)
  when SN == syn_sent; SN == connected; SN == connected_full; SN == fin_sent ->
    PKI1 = utp_pkt:zerowindow_timeout(TRef, PKI),
    {next_state, SN, State#state { pkt_window = PKI1 }};
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
	{ok, {receiver, From, Length, Res}, N_Processes} ->
	    case satisfy_buffer(From, Length, Res, Buffer) of
		{ok, N_Buffer} ->
		    satisfy_recvs(N_Processes, N_Buffer);
		{rb_drained, F, L, R, N_Buffer} ->
		    {rb_drained, utp_process:putback_receiver(F, L, R, N_Processes), N_Buffer}
	    end;
	empty ->
	    {ok, Processes, Buffer}
    end.



