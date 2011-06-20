-module(utp_socket).

-include("log.hrl").
-include("utp.hrl").

-export([
         mk/5,
         set_conn_id/2,
         update_reply_micro/2,
         packet_size/1,

         order_packets/2,
         conn_id_recv/1,
         send_reset/6,
         hostname_port/1,

         update_round_trip/2,
         rto/1,
         ack_packet_rtt/3,
         update_rtt_ledbat/2,
         update_our_ledbat/2,
         bump_ledbat/1,

         congestion_control/6
        ]).

-export([
         send_pkt/3, send_pkt/4
        ]).

-type ip_address() :: inet:ip4_address().
-type port_number() :: 0..16#FFFF.

-record(sock_info, {
	  %% Stuff pertaining to the socket:
	  addr        :: string() | ip_address(),
	  opts        :: [{atom(), term()}], %% Options on the socket
	  packet_size :: integer(),
	  port        :: port_number(),
	  socket      :: inet:socket(),
          conn_id_send :: 'not_set' | integer(),
          reply_micro :: integer(),
          round_trip  :: utp_rtt:t() | none,
          rtt_ledbat = none :: none | utp_ledbat:t(),
          our_ledbat = none :: none | utp_ledbat:t(),
          cwnd :: integer()
	 }).
-opaque t() :: #sock_info{}.
-export_type([t/0]).

%% ----------------------------------------------------------------------

-define(INITIAL_CWND, 3000).
mk(Addr, Opts, PacketSize, Port, Socket) ->
    #sock_info { addr = Addr,
                 opts = Opts,
                 packet_size = PacketSize,
                 port = Port,
                 socket = Socket,
                 conn_id_send = not_set,
                 reply_micro = 0,
                 round_trip = none,
                 cwnd = ?INITIAL_CWND
               }.

update_reply_micro(#sock_info {} = SockInfo, RU) ->
    SockInfo#sock_info { reply_micro = RU }.

hostname_port(#sock_info { addr = Addr, port = Port }) ->
    {Addr, Port}.

conn_id_recv(#sock_info { conn_id_send = ConnId }) ->
    ConnId - 1. % This is the receiver conn_id we use at the SYN point.

send_pkt(AdvWin, #sock_info { conn_id_send = ConnId } = SockInfo, Packet) ->
    send_pkt(AdvWin, SockInfo, Packet, ConnId).

send_pkt(AdvWin, #sock_info { socket = Socket,
                              addr = Addr,
                              port = Port,
                              reply_micro = TSDiff}, Packet, ConnId) ->
    Pkt = Packet#packet { conn_id = ConnId,
                          win_sz = AdvWin },
    ?DEBUG([node(), outgoing_pkt, utp_proto:format_pkt(Pkt)]),
    send(Socket, Addr, Port, Pkt, TSDiff).


send_reset(Socket, Addr, Port, ConnIDSend, AckNo, SeqNo) ->
    Packet =
        #packet { ty = st_reset,
                  ack_no = AckNo,
                  seq_no = SeqNo,
                  win_sz = 0,
                  extension = [],
                  conn_id = ConnIDSend },
    TSDiff = 0,
    send(Socket, Addr, Port, Packet, TSDiff).

send(Socket, Addr, Port, Packet, TSDiff) ->
    utp_proto:validate(Packet),
    send_aux(1, Socket, Addr, Port, utp_proto:encode(Packet, TSDiff)).

send_aux(0, Socket, Addr, Port, Payload) ->
    gen_udp:send(Socket, Addr, Port, Payload);
send_aux(N, Socket, Addr, Port, Payload) ->
    case gen_udp:send(Socket, Addr, Port, Payload) of
        ok ->
            {ok, utp_proto:current_time_us()};
        {error, enobufs} ->
            %% Special case this
            timer:sleep(150), % Wait a bit for the queue to clear
            send_aux(N-1, Socket, Addr, Port, Payload);
        {error, Reason} ->
            {error, Reason}
    end.
           

set_conn_id(Cid, SockInfo) ->
    SockInfo#sock_info { conn_id_send = Cid }.

order_packets(#packet { seq_no = S1 } = P1, #packet { seq_no = S2 } = P2) ->
    case S1 < S2 of
        true ->
            [P1, P2];
        false ->
            [P2, P1]
    end.

packet_size(_Socket) ->
    %% @todo FIX get_packet_size/1 to actually work!
    1000.

update_round_trip(V, #sock_info { round_trip = RTT } = SI) ->
    N_RTT = utp_rtt:update(V, RTT),
    SI#sock_info { round_trip = N_RTT }.

rto(#sock_info { round_trip = RTT }) ->
    utp_rtt:rto(RTT).

ack_packet_rtt(#sock_info { round_trip = RTT,
                            rtt_ledbat = LedbatHistory } = SI,
               TimeSent, TimeAcked) ->
    {ok, _NewRTO, NewRTT, NewHistory} = utp_rtt:ack_packet(LedbatHistory,
                                                           RTT,
                                                           TimeSent,
                                                           TimeAcked),
    SI#sock_info { round_trip = NewRTT,
                   rtt_ledbat     = NewHistory}.

update_rtt_ledbat(#sock_info { rtt_ledbat = none } = SockInfo, Sample) ->
    SockInfo#sock_info { rtt_ledbat = utp_ledbat:mk(Sample) };
update_rtt_ledbat(#sock_info { rtt_ledbat = Ledbat } = SockInfo, Sample) ->
    SockInfo#sock_info { rtt_ledbat = utp_ledbat:add_sample(Ledbat, Sample) }.

update_our_ledbat(#sock_info { our_ledbat = none } = SockInfo, Sample) ->
    SockInfo#sock_info { our_ledbat = utp_ledbat:mk(Sample) };
update_our_ledbat(#sock_info { our_ledbat = Ledbat } = SockInfo, Sample) ->
    SockInfo#sock_info { our_ledbat = utp_ledbat:add_sample(Ledbat, Sample) }.

bump_ledbat(#sock_info { rtt_ledbat = L,
                         our_ledbat = Our} = SockInfo) ->
    SockInfo#sock_info { rtt_ledbat = utp_ledbat:clock_tick(L),
                         our_ledbat = utp_ledbat:clock_tick(Our)}.
     

-define(CONGESTION_CONTROL_TARGET, 100). % ms, perhaps we should run this in us
-define(MAX_CWND_INCREASE_BYTES_PER_RTT, 3000). % bytes
-define(MIN_WINDOW_SIZE, 3000). % bytes
congestion_control(#sock_info { cwnd = Cwnd } = SockInfo,
                   MinRtt,
                   LastMaxedOutTime,
                   OptSndBuf,
                   BytesAcked,
                   OurHistory) ->
    true = MinRtt > 0,
    OurDelay = min(MinRtt, utp_ledbat:get_value(OurHistory)),
    true = OurDelay >= 0,

    TargetDelay = ?CONGESTION_CONTROL_TARGET,

    TargetOffset = OurDelay - TargetDelay,
    
    true = BytesAcked > 0,

    %% Compute the Window Factor. The window might have shrunk since
    %% last time, so take the minimum of the bytes acked and the
    %% window maximum.  Divide by the maximal value of the Windows and
    %% the bytes acked. This will yield a ratio which tells us how
    %% full the window is. If the window is 30K and we just acked 10K,
    %% then this value will be 10/30 = 1/3 meaning we have just acked
    %% 1/3 of the window. If the window has shrunk, the same holds,
    %% but opposite. We must make sure that only the size of the
    %% window is considered, so we track the minimum. that is, if the
    %% window has shrunk from 30 to 10, we only allow an update of the
    %% size 1/3 because this is the factor we can safely consider.
    WindowFactor = min(BytesAcked, Cwnd) / max(Cwnd, BytesAcked),

    %% The delay factor is how much we are off the target:
    DelayFactor = TargetOffset / TargetDelay,
    
    %% How much is the scaled gain?
    ScaledGain = ?MAX_CWND_INCREASE_BYTES_PER_RTT * WindowFactor * DelayFactor,
    
    true = ScaledGain =< 1 + ?MAX_CWND_INCREASE_BYTES_PER_RTT * min(BytesAcked, Cwnd)
        / max(Cwnd, BytesAcked),

    Alteration = case consider_last_maxed_window(LastMaxedOutTime) of
                     too_soon ->
                         0;
                     ok ->
                         ScaledGain
                 end,
    NewCwnd = clamp(Cwnd + Alteration, ?MIN_WINDOW_SIZE, OptSndBuf),
    SockInfo#sock_info {
      cwnd = NewCwnd
     }.


clamp(Val, Min, _Max) when Val < Min -> Min;
clamp(Val, _Min, Max) when Val > Max -> Max;
clamp(Val, _Min, _Max) -> Val.

consider_last_maxed_window(LastMaxedOutTime) ->    
    Now = utp_proto:current_time_ms(),
    case Now - LastMaxedOutTime > 300 of
        true ->
            too_soon;
        false ->
            ok
    end.







