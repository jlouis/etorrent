%%%-------------------------------------------------------------------
%%% @author Jesper Louis andersen <jesper.louis.andersen@gmail.com>
%%% @copyright (C) 2011, Jesper Louis andersen
%%% @doc
%%%
%%% @end
%%% Created : 19 Feb 2011 by Jesper Louis andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(gen_utp_worker).

-include("log.hrl").
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
	 got_fin/2, got_fin/3,
	 destroy_delay/2,
	 fin_sent/2, fin_sent/3,
	 reset/2, reset/3,
	 destroy/2]).

-type conn_state() :: idle | syn_sent | connected | got_fin
                    | destroy_delay | fin_sent | reset | destroy.

-type error_type() :: econnreset | econnrefused | etiemedout | emsgsize.
-type ret_value()  :: ok | {ok, binary()} | {error, error_type()}.

-export_type([conn_state/0,
              error_type/0,
              ret_value/0]).

-define(SERVER, ?MODULE).
%% Default extensions to use when SYN/SYNACK'ing
-define(SYN_EXTS, [{ext_bits, <<0:64/integer>>}]).

%% Default SYN packet timeout
-define(SYN_TIMEOUT, 3000).
-define(DEFAULT_RETRANSMIT_TIMEOUT, 3000).
-define(SYN_TIMEOUT_THRESHOLD, ?SYN_TIMEOUT*2).
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

%% Default timeout value for sockets where we will destroy them!
-define(RTO_DESTROY_VALUE, 30*1000).

%% The delay to set on Zero Windows. It is awfully high, but that is what it has
%% to be it seems.
-define(ZERO_WINDOW_DELAY, 15*1000).

%% Experiments suggest that a clock skew of 10 ms per 325 seconds
%% is not impossible. Reset delay_base every 13 minutes. The clock
%% skew is dealt with by observing the delay base in the other
%% direction, and adjusting our own upwards if the opposite direction
%% delay base keeps going down
-define(DELAY_BASE_HISTORY, 13).
-define(MAX_WINDOW_DECAY, 100). % ms

-define(DEFAULT_OPT_RECV_SZ, 8192). %% @todo Fix this
-define(DEFAULT_PACKET_SIZE, 350). %% @todo Fix, arbitrary at the moment

-define(DEFAULT_FSM_TIMEOUT, 10*60*1000).
%% STATE RECORDS
%% ----------------------------------------------------------------------
-record(state, { network :: utp_network:t(),
                 buffer      :: utp_pkt:t(),
                 process    :: utp_process:t(),
                 connector    :: {{reference(), pid()}, [{pkt, #packet{}, term()}]},
                 zerowindow_timeout :: undefined | {set, reference()},
                 retransmit_timeout :: undefined | {set, reference()},
                 delayed_ack_timeout :: undefined | {set, integer(), reference()},
                 options = [] :: [{atom(), term()}]
               }).

%%%===================================================================

%% @doc Create a worker for a peer endpoint
%% @end
start_link(Socket, Addr, Port, Options) ->
    gen_fsm:start_link(?MODULE, [Socket, Addr, Port, Options], []).

%% @doc Send a connect event
%% @end
connect(Pid) ->
    sync_send_event(Pid, connect).

%% @doc Send an accept event
%% @end
accept(Pid, SynPacket) ->
    sync_send_event(Pid, {accept, SynPacket}).

%% @doc Receive some bytes from the socket. Blocks until the said amount of
%% bytes have been read.
%% @end
recv(Pid, Amount) ->
    gen_fsm:sync_send_event(Pid, {recv, Amount}, infinity).

%% @doc Send some bytes from the socket. Blocks until the said amount of
%% bytes have been sent and has been accepted by the underlying layer.
%% @end
send(Pid, Data) ->
    gen_fsm:sync_send_event(Pid, {send, Data}, infinity).

%% @doc Send a close event
%% @end
close(Pid) ->
    %% Consider making it sync, but the de-facto implementation isn't
    gen_fsm:send_event(Pid, close).

%% ----------------------------------------------------------------------
incoming(Pid, Packet, Timing) ->
    utp:report_event(50, peer, us, utp_proto:succinct_format_packet(Packet), [{packet, Packet}]),
    gen_fsm:send_event(Pid, {pkt, Packet, Timing}).

reply(To, Msg) ->
    gen_fsm:reply(To, Msg).

sync_send_event(Pid, Event) ->
    gen_fsm:sync_send_event(Pid, Event, ?DEFAULT_FSM_TIMEOUT).


%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

%% @private
init([Socket, Addr, Port, Options]) ->
    case validate_options(Options) of
        ok ->
            PktBuf   = utp_buffer:mk(?DEFAULT_OPT_RECV_SZ),
            ProcInfo = utp_process:mk(),
            CanonAddr = utp_util:canonicalize_address(Addr),
            SockInfo = utp_socket:mk(CanonAddr, Options, Port, Socket),
            Network  = utp_network:mk(?DEFAULT_PACKET_SIZE, SockInfo),
            {ok, report(idle), #state{ network = Network,
                                       buffer   = PktBuf,
                                       process = ProcInfo,
                                       options=  Options }};
        badarg ->
            {report(stop), badarg}
    end.

%% @private
idle(close, S) ->
    {next_state, report(destroy), S, 0};
idle(_Msg, S) ->
    %% Ignore messages
    ?ERR([node(), async_message, idle, _Msg]),
    {next_state, idle, S}.

%% @private
syn_sent({pkt, #packet { ty = st_reset }, _},
         #state { process = PRI,
                  connector = {From, _} } = State) ->
    %% We received a reset packet in the connected state. This means an abrupt
    %% disconnect, so move to the RESET state right away after telling people
    %% we can't fulfill their requests.
    N_PRI = utp_process:error_all(PRI, econnrefused),
    %% Also handle the guy making the connection
    reply(From, econnrefused),
    {next_state, report(destroy), State#state { process = N_PRI }, 0};
syn_sent({pkt, #packet { ty = st_state,
                         win_sz = WindowSize,
			 seq_no = PktSeqNo },
	       {TS, TSDiff, RecvTime}},
	 #state { network = Network,
                  buffer = PktBuf,
                  connector = {From, Packets},
                  retransmit_timeout = RTimeout
                } = State) ->
    reply(From, ok),
    %% Empty the queue of packets for the new state
    %% We reverse the list so they are in the order we got them originally
    [incoming(self(), P, T) || {pkt, P, T} <- lists:reverse(Packets)],
    %% @todo Consider LEDBAT here
    ReplyMicro = utp_util:bit32(TS - RecvTime),
    set_ledbat_timer(),
    N2 = utp_network:handle_advertised_window(Network, WindowSize),
    N_Network = utp_network:update_our_ledbat(N2, TSDiff),
    {next_state, report(connected),
     State#state { network = utp_network:update_reply_micro(N_Network, ReplyMicro),
                   retransmit_timeout = clear_retransmit_timer(RTimeout),
                  buffer = utp_buffer:init_ackno(PktBuf, utp_util:bit16(PktSeqNo + 1))}};
syn_sent({pkt, _Packet, _Timing} = Pkt,
         #state { connector = {From, Packets}} = State) ->
    {next_state, syn_sent,
     State#state {
       connector = {From, [Pkt | Packets]}}};
syn_sent(close, #state {
           network = Network,
           retransmit_timeout = RTimeout
          } = State) ->
    clear_retransmit_timer(RTimeout),
    Gracetime = lists:min([60, utp_network:rto(Network) * 2]),
    Timer = set_retransmit_timer(Gracetime, undefined),
    {next_state, syn_sent, State#state {
                             retransmit_timeout = Timer }};
syn_sent({timeout, TRef, {retransmit_timeout, N}},
         #state { retransmit_timeout = {set, TRef},
                  network = Network,
                  connector = {From, _},
                  buffer = PktBuf
                } = State) ->
    case N > ?SYN_TIMEOUT_THRESHOLD of
        true ->
            reply(From, {error, etimedout}),
            {next_state, report(reset), State#state {retransmit_timeout = undefined}};
        false ->
            % Resend packet
            SynPacket = utp_proto:mk_syn(),
            Win = utp_buffer:advertised_window(PktBuf),
            {ok, _} = utp_network:send_pkt(Win, Network, SynPacket, conn_id_recv),
            {next_state, syn_sent,
             State#state {
               retransmit_timeout = set_retransmit_timer(N*2, undefined)
              }}
    end;
syn_sent(_Msg, S) ->
    %% Ignore messages
    ?ERR([node(), async_message, syn_sent, _Msg]),
    {next_state, syn_sent, S}.


%% @private
connected({pkt, #packet { ty = st_reset }, _},
          #state { process = PRI } = State) ->
    %% We received a reset packet in the connected state. This means an abrupt
    %% disconnect, so move to the RESET state right away after telling people
    %% we can't fulfill their requests.
    N_PRI = utp_process:error_all(PRI, econnreset),
    {next_state, report(reset), State#state { process = N_PRI }};
connected({pkt, #packet { ty = st_syn }, _}, State) ->
    ?INFO([duplicate_syn_packet, ignoring]),
    {next_state, connected, State};
connected({pkt, Pkt, {TS, TSDiff, RecvTime}}, State) ->
    {ok, Messages, N_Network, N_PB, N_PRI, ZWinTimeout, N_DelayAck, N_RetransTimer} =
        handle_packet_incoming(connected,
                               Pkt, utp_util:bit32(TS - RecvTime), RecvTime, TSDiff, State),

    NextState = case proplists:get_value(got_fin, Messages) of
                    true -> report(got_fin);
                    undefined -> connected
                end,
    {next_state, NextState,
     State#state { buffer = N_PB,
                   network = N_Network,
                   retransmit_timeout = N_RetransTimer,
                   zerowindow_timeout = ZWinTimeout,
                   delayed_ack_timeout = N_DelayAck,
                   process = N_PRI }};
connected(close, #state { network = Network,
                          buffer = PktBuf } = State) ->
    NPBuf = utp_buffer:send_fin(Network, PktBuf),
    {next_state, report(fin_sent), State#state { buffer = NPBuf } };
connected({timeout, _, ledbat_timeout}, State) ->
    {next_state, connected, bump_ledbat(State)};
connected({timeout, Ref, send_delayed_ack}, State) ->
    {next_state, connected, trigger_delayed_ack(Ref, State)};
connected({timeout, Ref, {zerowindow_timeout, _N}},
          #state {
            buffer = PktBuf,
            process = ProcessInfo,
            network = Network,
            zerowindow_timeout = {set, Ref}} = State) ->
    N_Network = utp_network:bump_window(Network),
    {_FillMessages, ZWinTimer, N_PktBuf, N_ProcessInfo} =
        fill_window(N_Network, ProcessInfo, PktBuf, undefined),
    {next_state, connected,
     State#state {
       zerowindow_timeout = ZWinTimer,
       buffer = N_PktBuf,
       process = N_ProcessInfo}};
connected({timeout, Ref, {retransmit_timeout, N}},
         #state { 
            buffer = PacketBuf,
            network = Network,
            retransmit_timeout = {set, Ref} = Timer} = State) ->
    case handle_timeout(Ref, N, PacketBuf, Network, Timer) of
        stray ->
            {next_state, connected, State};
        gave_up ->
            {next_state, report(reset), State};
        {reinstalled, N_Timer, N_PB, N_Network} ->
            {next_state, connected, State#state { retransmit_timeout = N_Timer,
                                                  network = N_Network,
                                                  buffer = N_PB }}
    end;
connected(_Msg, State) ->
    %% Ignore messages
    ?ERR([node(), async_message, connected, _Msg]),
    {next_state, connected, State}.

%% @private
got_fin(close, #state { 
          retransmit_timeout = Timer,
          network = Network } = State) ->
    N_Timer = set_retransmit_timer(utp_network:rto(Network), Timer),
    {next_state, report(destroy_delay), State#state { retransmit_timeout = N_Timer } };
got_fin({timeout, Ref, {retransmit_timeout, N}},
        #state { 
          buffer = PacketBuf,
          network = Network,
          retransmit_timeout = Timer} = State) ->
    case handle_timeout(Ref, N, PacketBuf, Network, Timer) of
        stray ->
            {next_state, got_fin, State};
        gave_up ->
            {next_state, report(reset), State};
        {reinstalled, N_Timer, N_PB, N_Network} ->
            {next_state, got_fin, State#state { retransmit_timeout = N_Timer,
                                                network = N_Network,
                                                buffer = N_PB }}
    end;
got_fin({timeout, Ref, send_delayed_ack}, State) ->
    {next_state, got_fin, trigger_delayed_ack(Ref, State)};
got_fin({pkt, #packet { ty = st_state }, _}, State) ->
    %% State packets incoming can be ignored. Why? Because state packets from the other
    %% end doesn't matter at this point: We got the FIN completed, so we can't send or receive
    %% anymore. And all who were waiting are expunged from the receive buffer. No new can enter.
    %% Our Timeout will move us on (or a close). The other end is in the FIN_SENT state, so
    %% he will only send state packets when he needs to ack some of our stuff, which he wont.
    {next_state, got_fin, State};
got_fin({pkt, #packet { ty = st_fin }, _}, State) ->
    %% @todo We should probably send out an ACK for the FIN here since it is a retransmit
    {next_state, got_fin, State};
got_fin(_Msg, State) ->
    %% Ignore messages
    ?ERR([node(), async_message, got_fin, _Msg]),
    {next_state, got_fin, State}.

%% @private
destroy_delay({timeout, Ref, {retransmit_timeout, _N}},
         #state { retransmit_timeout = {set, Ref} } = State) ->
    {next_state, report(destroy), State#state { retransmit_timeout = undefined }, 0};
destroy_delay({timeout, Ref, send_delayed_ack}, State) ->
    {next_state, destroy_delay, trigger_delayed_ack(Ref, State)};
destroy_delay({pkt, #packet { ty = st_fin }, _}, State) ->
    {next_state, destroy_delay, State};
destroy_delay(close, State) ->
    {next_state, report(destroy), State, 0};
destroy_delay(_Msg, State) ->
    %% Ignore messages
    ?ERR([node(), async_message, destroy_delay, _Msg]),
    {next_state, destroy_delay, State}.

%% @private
%% Die deliberately on close for now
fin_sent({pkt, #packet { ty = st_syn }, _},
         State) ->
    %% Quaff SYN packets if they arrive in this state. They are stray.
    %% I have seen it happen in tests, however unlikely that it happens in real life.
    {next_state, fin_sent, State};
fin_sent({pkt, #packet { ty = st_reset }, _},
         #state { process = PRI } = State) ->
    %% We received a reset packet in the connected state. This means an abrupt
    %% disconnect, so move to the RESET state right away after telling people
    %% we can't fulfill their requests.
    N_PRI = utp_process:error_all(PRI, econnreset),
    {next_state, report(destroy), State#state { process = N_PRI }};
fin_sent({pkt, Pkt, {TS, TSDiff, RecvTime}}, State) ->
    {ok, Messages, N_Network, N_PB, N_PRI, ZWinTimeout, N_DelayAck, N_RetransTimer} =
        handle_packet_incoming(fin_sent,
                               Pkt, utp_util:bit32(TS - RecvTime), RecvTime, TSDiff, State),
    %% Calculate the next state
    N_State = State#state {
                buffer = N_PB,
                network = N_Network,
                retransmit_timeout = N_RetransTimer,
                zerowindow_timeout = ZWinTimeout,
                delayed_ack_timeout = N_DelayAck,
                process = N_PRI },
    case proplists:get_value(fin_sent_acked, Messages) of
        true ->
            {next_state, report(destroy), N_State, 0};
        undefined ->
            {next_state, fin_sent, N_State}
    end;
fin_sent({timeout, _, ledbat_timeout}, State) ->
    {next_state, fin_sent, bump_ledbat(State)};
fin_sent({timeout, Ref, send_delayed_ack}, State) ->
    {next_state, fin_sent, trigger_delayed_ack(Ref, State)};
fin_sent({timeout, Ref, {retransmit_timeout, N}},
         #state { buffer = PacketBuf,
                  network = Network,
                  retransmit_timeout = Timer} = State) ->
    case handle_timeout(Ref, N, PacketBuf, Network, Timer) of
        stray ->
            {next_state, fin_sent, State};
        gave_up ->
            {next_state, report(destroy), State, 0};
        {reinstalled, N_Timer, N_PB, N_Network} ->
            {next_state, fin_sent, State#state { retransmit_timeout = N_Timer,
                                                 network = N_Network,
                                                 buffer = N_PB }}
    end;
fin_sent(_Msg, State) ->
    %% Ignore messages
    ?ERR([node(), async_message, fin_sent, _Msg]),
    {next_state, fin_sent, State}.

%% @private
reset(close, State) ->
    {next_state, report(destroy), State, 0};
reset(_Msg, State) ->
    %% Ignore messages
    ?ERR([node(), async_message, reset, _Msg]),
    {next_state, reset, State}.

%% @private
%% Die deliberately on close for now
destroy(timeout, #state { process = ProcessInfo } = State) ->
    N_ProcessInfo = utp_process:error_all(ProcessInfo, econnreset),
    {report(stop), normal, State#state { process = N_ProcessInfo }};
destroy(_Msg, State) ->
    %% Ignore messages
    ?ERR([node(), async_message, destroy, _Msg]),
    {next_state, destroy, State}.

%% @private
idle(connect,
     From, State = #state { network = Network,
                            buffer = PktBuf}) ->
    {Address, Port} = utp_network:hostname_port(Network),
    Conn_id_recv = utp_proto:mk_connection_id(),
    gen_utp:register_process(self(), {Conn_id_recv, Address, Port}),
    N_Network = utp_network:set_conn_id(Conn_id_recv + 1, Network),

    SynPacket = utp_proto:mk_syn(),
    send_pkt(PktBuf, N_Network, SynPacket),

    {next_state, report(syn_sent),
     State#state { network = N_Network,
                   retransmit_timeout = set_retransmit_timer(?SYN_TIMEOUT, undefined),
                  buffer     = utp_buffer:init_seqno(PktBuf, 2),
                  connector = {From, []}}};
idle({accept, SYN}, _From, #state { network = Network,
                                    options = Options,
                                    buffer   = PktBuf } = State) ->
    utp:report_event(50, peer, us, utp_proto:succinct_format_packet(SYN), [{packet, SYN}]),
    1 = SYN#packet.seq_no,
    Conn_id_send = SYN#packet.conn_id,
    N_Network = utp_network:set_conn_id(Conn_id_send, Network),
    SeqNo = init_seq_no(Options),

    AckPacket = utp_proto:mk_ack(SeqNo, SYN#packet.seq_no),
    Win = utp_buffer:advertised_window(PktBuf),
    {ok, _} = utp_network:send_pkt(Win, N_Network, AckPacket),

    %% @todo retransmit timer here?
    set_ledbat_timer(),
    {reply, ok, report(connected),
            State#state { network = utp_network:handle_advertised_window(N_Network, SYN),
                          buffer = utp_buffer:init_counters(PktBuf,
                                                             utp_util:bit16(SeqNo + 1),
                                                             utp_util:bit16(SYN#packet.seq_no + 1))}};

idle(_Msg, _From, State) ->
    {reply, idle, {error, enotconn}, State}.

init_seq_no(Options) ->
    case proplists:get_value(force_seq_no, Options) of
        undefined -> utp_buffer:mk_random_seq_no();
        K -> K
    end.


send_pkt(PktBuf, N_Network, SynPacket) ->
    Win = utp_buffer:advertised_window(PktBuf),
    {ok, _} = utp_network:send_pkt(Win, N_Network, SynPacket, conn_id_recv).

%% @private
connected({recv, Length}, From, #state { process = PI,
                                         network = Network,
                                         delayed_ack_timeout = DelayAckT,
                                         buffer   = PKB } = State) ->
    PI1 = utp_process:enqueue_receiver(From, Length, PI),
    case satisfy_recvs(PI1, PKB) of
        {_, N_PRI, N_PKB} ->
            N_Delay = case utp_buffer:view_zerowindow_reopen(PKB, N_PKB) of
                          true ->
                              handle_send_ack(Network, N_PKB, DelayAckT,
                                              [send_ack, no_piggyback], 0);
                          false ->
                              DelayAckT
                      end,
            {next_state, connected, State#state { process = N_PRI,
                                                  delayed_ack_timeout = N_Delay,
                                                  buffer   = N_PKB } }
    end;
connected({send, Data}, From, #state {
                          network = Network,
			  process = PI,
                          retransmit_timeout = RTimer,
                          zerowindow_timeout = ZWinTimer,
			  buffer   = PKB } = State) ->
    ProcInfo = utp_process:enqueue_sender(From, Data, PI),
    {FillMessages, N_ZWinTimer, PKB1, ProcInfo1} =
        fill_window(Network,
                    ProcInfo,
                    PKB,
                    ZWinTimer),
    N_RTimer = handle_send_retransmit_timer(FillMessages, Network, RTimer),
    {next_state, connected, State#state {
                              zerowindow_timeout = N_ZWinTimer,
                              retransmit_timeout = N_RTimer,
			      process = ProcInfo1,
			      buffer   = PKB1 }};
connected(_Msg, _From, State) ->
    ?ERR([sync_message, connected, _Msg, _From]),
    {next_state, connected, State}.

%% @private
got_fin({recv, L}, _From, #state { buffer = PktBuf,
                                   process = ProcInfo } = State) ->
    true = utp_process:recv_buffer_empty(ProcInfo),
    case utp_buffer:draining_receive(L, PktBuf) of
        {ok, Bin, N_PktBuf} ->
            {reply, {ok, Bin}, got_fin, State#state { buffer = N_PktBuf}};
        empty ->
            {reply, {error, eof}, got_fin, State};
        {partial_read, Bin, N_PktBuf} ->
            {reply, {error, {partial, Bin}}, got_fin, State#state { buffer = N_PktBuf}}
    end;
got_fin({send, _Data}, _From, State) ->
    {reply, {error, econnreset}, got_fin, State}.

%% @private
fin_sent({recv, L}, _From, #state { buffer = PktBuf,
                                    process = ProcInfo } = State) ->
    true = utp_process:recv_buffer_empty(ProcInfo),
    case utp_buffer:draining_receive(L, PktBuf) of
        {ok, Bin, N_PktBuf} ->
            {reply, {ok, Bin}, fin_sent, State#state { buffer = N_PktBuf}};
        empty ->
            {reply, {error, eof}, fin_sent, State};
        {partial_read, Bin, N_PktBuf} ->
            {reply, {error, {partial, Bin}}, fin_sent, State#state { buffer = N_PktBuf}}
    end;
fin_sent({send, _Data}, _From, State) ->
    {reply, {error, econnreset}, fin_sent, State}.

%% @private
reset({recv, _L}, _From, State) ->
    {reply, {error, econnreset}, reset, State};
reset({send, _Data}, _From, State) ->
    {reply, {error, econnreset}, reset, State}.

%% @private
handle_event(_Event, StateName, State) ->
    ?ERR([unknown_handle_event, _Event, StateName, State]),
    {next_state, StateName, State}.

%% @private
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
    case utp_buffer:buffer_dequeue(Buffer) of
	{ok, Bin, N_Buffer} when byte_size(Bin) =< Length ->
	    satisfy_buffer(From, Length - byte_size(Bin), <<Res/binary, Bin/binary>>, N_Buffer);
	{ok, Bin, N_Buffer} when byte_size(Bin) > Length ->
	    <<Cut:Length/binary, Rest/binary>> = Bin,
	    satisfy_buffer(From, 0, <<Res/binary, Cut/binary>>,
			   utp_buffer:buffer_putback(Rest, N_Buffer));
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

set_retransmit_timer(N, Timer) ->
    set_retransmit_timer(N, N, Timer).

set_retransmit_timer(N, K, undefined) ->
    Ref = gen_fsm:start_timer(N, {retransmit_timeout, K}),
    {set, Ref};
set_retransmit_timer(N, K, {set, Ref}) ->
    gen_fsm:cancel_timer(Ref),
    N_Ref = gen_fsm:start_timer(N, {retransmit_timeout, K}),
    {set, N_Ref}.

clear_retransmit_timer(undefined) ->
    undefined;
clear_retransmit_timer({set, Ref}) ->
    gen_fsm:cancel_timer(Ref),
    undefined.

%% @doc Handle the retransmit timer in the send direction
handle_send_retransmit_timer(Messages, Network, RetransTimer) ->
    case proplists:get_value(sent_data, Messages) of
        true ->
            set_retransmit_timer(utp_network:rto(Network), RetransTimer);
        undefined ->
            %% We sent nothing out, just use the current timer
            RetransTimer
    end.

handle_recv_retransmit_timer(Messages, Network, RetransTimer) ->
    Analyzer = fun(L) -> lists:foldl(is_set(Messages), false, L) end,
    case Analyzer([data_inflight, fin_sent]) of
        true ->
            set_retransmit_timer(utp_network:rto(Network), RetransTimer);
        false ->
            case Analyzer([all_acked]) of
                true ->
                    clear_retransmit_timer(RetransTimer);
                false ->
                    RetransTimer % Just pass it along with no update
            end
    end.

is_set(Messages) ->
    fun(E, Acc) ->
            case proplists:get_value(E, Messages) of
                true ->
                    true;
                undefined ->
                    Acc
            end
    end.

fill_window(Network, ProcessInfo, PktBuffer, ZWinTimer) ->
    {Messages, N_PktBuffer, N_ProcessInfo} =
        utp_buffer:fill_window(Network,
                               ProcessInfo,
                               PktBuffer),
    %% Capture and handle the case where the other end has given up in
    %% the space department of its receive buffer.
    case utp_network:view_zero_window(Network) of
        ok ->
            {Messages, cancel_zerowin_timer(ZWinTimer), N_PktBuffer, N_ProcessInfo};
        zero ->
            {Messages, set_zerowin_timer(ZWinTimer), N_PktBuffer, N_ProcessInfo}
    end.

cancel_zerowin_timer(undefined) -> undefined;
cancel_zerowin_timer({set, Ref}) ->
    gen_fsm:cancel_timer(Ref),
    undefined.

set_zerowin_timer(undefined) ->
    Ref = gen_fsm:start_timer(?ZERO_WINDOW_DELAY,
                              {zerowindow_timeout, ?ZERO_WINDOW_DELAY}),
    {set, Ref};
set_zerowin_timer({set, Ref}) -> {set, Ref}. % Already set, do nothing

handle_packet_incoming(FSMState, Pkt, ReplyMicro, TimeAcked, TSDiff,
                       #state { buffer = PB,
                                process = PRI,
                                network = Network,
                                zerowindow_timeout = ZWin,
                                retransmit_timeout = RetransTimer,
                                delayed_ack_timeout = DelayAckT
                             }) ->
    %% Handle the incoming packet
    try
        utp_buffer:handle_packet(FSMState, Pkt, Network, PB)
    of
        {ok, N_PB1, N_Network3, RecvMessages} ->
            N_Network2 = utp_network:update_window(N_Network3, ReplyMicro, TimeAcked, RecvMessages, TSDiff, Pkt),
            %% The packet may bump the advertised window from the peer, update
            %% The incoming datagram may have payload we can deliver to an application
            {_Drainage, N_PRI, N_PB} = satisfy_recvs(PRI, N_PB1),
            
            %% Fill up the send window again with the new information
            {FillMessages, ZWinTimeout, N_PB2, N_PRI2} =
                fill_window(N_Network2, N_PRI, N_PB, ZWin),

            Messages = RecvMessages ++ FillMessages,

            N_Network = utp_network:handle_maxed_out_window(Messages, N_Network2),
            %% @todo This ACK may be cancelled if we manage to push something out
            %%       the window, etc., but the code is currently ready for it!
            %% The trick is to clear the message.

            %% Send out an ACK if needed
            AckedBytes = acked_bytes(Messages),
            N_DelayAckT = handle_send_ack(N_Network, N_PB2,
                                          DelayAckT,
                                          Messages,
                                          AckedBytes),
            N_RetransTimer =  handle_recv_retransmit_timer(Messages, N_Network, RetransTimer),

            {ok, Messages, N_Network, N_PB2, N_PRI2, ZWinTimeout, N_DelayAckT, N_RetransTimer}
    catch
        throw:{error, is_far_in_future} ->
            {ok, [], Network, PB, PRI, ZWin, DelayAckT}
    end.

acked_bytes(Messages) ->
    case proplists:get_value(acked, Messages) of
        undefined ->
            0;
        Acked when is_list(Acked) ->
            utp_buffer:extract_payload_size(Acked)
    end.

handle_timeout(Ref, N, PacketBuf, Network, {set, Ref} = Timer) ->
    case N > ?RTO_DESTROY_VALUE of
        true ->
            gave_up;
        false ->
            N_Timer = set_retransmit_timer(N*2, Timer),
            N_PB = utp_buffer:retransmit_packet(PacketBuf, Network),
            N_Network = utp_network:reset_window(Network),
            {reinstalled, N_Timer, N_PB, N_Network}
    end;
handle_timeout(_Ref, _N, _PacketBuf, _Network, _Timer) ->
    ?ERR([stray_retransmit_timer, _Ref, _N, _Timer]),
    stray.

-spec validate_options([term()]) -> ok | badarg.
validate_options([{backlog, N} | R]) ->
    case is_integer(N) of
        true ->
            validate_options(R);
        false ->
            badarg
    end;
validate_options([{force_seq_no, N} | R]) ->
    case is_integer(N) of
        true when N >= 0,
                  N =< 16#FFFF ->
            validate_options(R);
        true ->
            badarg;
        false ->
            badarg
    end;
validate_options([]) ->
    ok;
validate_options(_) ->
    badarg.

set_ledbat_timer() ->
    gen_fsm:start_timer(timer:seconds(60), ledbat_timeout).

bump_ledbat(#state { network = Network } = State) ->
    N_Network = utp_network:bump_ledbat(Network),
    set_ledbat_timer(),
    State#state { network = N_Network }.
    
trigger_delayed_ack(Ref, #state {
                       buffer = PktBuf,
                       network = Network,
                       delayed_ack_timeout = {set, _, Ref}
                      } = State) ->
    utp_buffer:send_ack(Network, PktBuf),
    State#state { delayed_ack_timeout = undefined }.

cancel_delayed_ack(undefined) ->
    undefined; %% It was never there, ignore it
cancel_delayed_ack({set, _Count, Ref}) ->
    gen_fsm:cancel_timer(Ref),
    undefined.

handle_delayed_ack(undefined, AckedBytes, Network, PktBuf)
  when AckedBytes >= ?DELAYED_ACK_BYTE_THRESHOLD ->
    utp_buffer:send_ack(Network, PktBuf),
    undefined;
handle_delayed_ack(undefined, AckedBytes, _Network, _PktBuf) ->
    Ref = gen_fsm:start_timer(?DELAYED_ACK_TIME_THRESHOLD, send_delayed_ack),
    {set, AckedBytes, Ref};
handle_delayed_ack({set, ByteCount, _Ref} = DelayAck, AckedBytes, Network, PktBuf)
  when ByteCount+AckedBytes >= ?DELAYED_ACK_BYTE_THRESHOLD ->
    utp_buffer:send_ack(Network, PktBuf),
    cancel_delayed_ack(DelayAck);
handle_delayed_ack({set, ByteCount, Ref}, AckedBytes, _Network, _PktBuf) ->
    {set, ByteCount+AckedBytes, Ref}.

%% @doc Consider if we should send out an ACK and do it if so
%% @end
handle_send_ack(Network, PktBuf, DelayAck, Messages, AckedBytes) ->
    case view_ack_messages(Messages) of
        nothing ->
            DelayAck;
        got_fin ->
            utp_buffer:send_ack(Network, PktBuf),
            cancel_delayed_ack(DelayAck);
        no_piggyback ->
            handle_delayed_ack(DelayAck, AckedBytes, Network, PktBuf);
        piggybacked ->
            %% The requested ACK is already sent as a piggyback on
            %% top of a data message. There is no reason to resend it.
            cancel_delayed_ack(DelayAck)
    end.

view_ack_messages(Messages) ->
    case proplists:get_value(send_ack, Messages) of
        undefined ->
            nothing;
        true ->
            ack_analyze_further(Messages)
    end.

ack_analyze_further(Messages) ->
    case proplists:get_value(got_fin, Messages) of
        true ->
            got_fin;
        undefined ->
            case proplists:get_value(no_piggyback, Messages) of
                true ->
                    no_piggyback;
                undefined ->
                    piggybacked
            end
    end.

report(NewState) ->
    utp:report_event(50, us, NewState, []),
    NewState.

