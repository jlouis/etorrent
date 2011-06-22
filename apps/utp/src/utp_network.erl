%% @doc Handle anything network-related
%% This module handles everything
%% network-related on an uTP socket. This includes the peer
%% information and the static information present on a socket.
%% @end
-module(utp_network).

-include("utp.hrl").
-include("log.hrl").

-export([
         handle_window_size/2,
         handle_advertised_window/2,
         mk/2,

         update_reply_micro/2,

         ack_packet_rtt/3,
         update_rtt_ledbat/2,
         update_our_ledbat/2,
         bump_ledbat/1,

         view_zero_window/1,
         bump_window/1,
         rto/1,
         max_window_send/2,
         congestion_control/6,
         hostname_port/1,
         set_conn_id/2
        ]).

-export([
         send_pkt/3, send_pkt/4
        ]).

-record(network, {
          %% Static Socket info information
          sock_info :: utp_socket:t(),

          %% Size of the window the Peer advertises to us.
          peer_advertised_window = 4096 :: integer(),

          %% The current window size in the send direction, in bytes.
          cur_window :: integer(),
          %% Maximal window size int the send direction, in bytes.
          %% Also known as the current congestion window
          cwnd :: integer(),

          %% Current packet size. We can alter the packet size if we want, but we
          %% cannot repacketize.
	  packet_size :: integer(),

          %% Current value to reply back to the other end
          reply_micro :: integer(),

          %% Round trip time measurements and LEDBAT
          round_trip  :: utp_rtt:t() | none,
          rtt_ledbat = none :: none | utp_ledbat:t(),
          our_ledbat = none :: none | utp_ledbat:t(),

          %% Timeouts,
          %% --------------------
          %% Set when we update the zero window to 0 so we can reset it to 1.
          zero_window_timeout :: none | {set, reference()},
          rto = 3000 :: integer(), % Retransmit timeout default

          %% Timestamps
          %% --------------------
          %% When was the window last totally full (in send direction)
          last_maxed_out_window :: integer()
       }).


-opaque t() :: #network{}.
-export_type([t/0]).

-define(INITIAL_CWND, 3000).

%% ----------------------------------------------------------------------
-spec mk(integer(),
         utp_socket:t()) -> t().
mk(PacketSize, SockInfo) ->
    #network { packet_size = PacketSize,
               sock_info   = SockInfo,
               reply_micro = 0,
               round_trip = none,
               cwnd = ?INITIAL_CWND
             }.

update_reply_micro(#network {} = SockInfo, RU) ->
    SockInfo#network { reply_micro = RU }.


update_round_trip(V, #network { round_trip = RTT } = NW) ->
    N_RTT = utp_rtt:update(V, RTT),
    NW#network { round_trip = N_RTT }.

handle_advertised_window(PKW, #packet { win_sz = Win }) ->
    handle_advertised_window(PKW, Win);
handle_advertised_window(#network{} = PKWin, NewWin) when is_integer(NewWin) ->
    PKWin#network { peer_advertised_window = NewWin }.

handle_window_size(#network {} = PKI, WindowSize) ->
    PKI#network { peer_advertised_window = WindowSize }.

max_window_send(SendBufSz,
                #network { peer_advertised_window = AdvertisedWindow,
                           cwnd = MaxSendWindow }) ->
    lists:min([SendBufSz, AdvertisedWindow, MaxSendWindow]).

view_zero_window(#network { peer_advertised_window = N }) when N > 0 ->
    ok; % There is no reason to update the window
view_zero_window(#network { peer_advertised_window = 0 }) ->
    zero.

set_conn_id(ConnIDSend, #network { sock_info = SI } = NW) ->
    N = utp_socket:set_conn_id(ConnIDSend, SI),
    NW#network { sock_info = N }.
            
bump_window(#network {} = Win) ->
    PacketSize = utp_socket:packet_size(todo),
    Win#network {
      peer_advertised_window = PacketSize
     }.

hostname_port(#network { sock_info = SI}) ->
    utp_socket:hostname_port(SI).

send_pkt(AdvWin, #network { sock_info = SockInfo } = Network, Packet) ->
    send_pkt(AdvWin, Network, Packet, utp_socket:conn_id(SockInfo)).

send_pkt(AdvWin,
         #network { sock_info = SockInfo,
                    reply_micro = TSDiff}, Packet, ConnId) ->
    Pkt = Packet#packet { conn_id = ConnId,
                          win_sz = AdvWin },
    ?DEBUG([node(), outgoing_pkt, utp_proto:format_pkt(Pkt)]),
    utp_socket:send_pkt(SockInfo, Pkt, TSDiff).

rto(#network { round_trip = RTT }) ->
    utp_rtt:rto(RTT).

ack_packet_rtt(#network { round_trip = RTT,
                          rtt_ledbat = LedbatHistory } = NW,
               TimeSent, TimeAcked) ->
    {ok, _NewRTO, NewRTT, NewHistory} = utp_rtt:ack_packet(LedbatHistory,
                                                           RTT,
                                                           TimeSent,
                                                           TimeAcked),
    NW#network { round_trip = NewRTT,
                   rtt_ledbat     = NewHistory}.


update_rtt_ledbat(#network { rtt_ledbat = none } = SockInfo, Sample) ->
    SockInfo#network { rtt_ledbat = utp_ledbat:mk(Sample) };
update_rtt_ledbat(#network { rtt_ledbat = Ledbat } = SockInfo, Sample) ->
    SockInfo#network { rtt_ledbat = utp_ledbat:add_sample(Ledbat, Sample) }.

update_our_ledbat(#network { our_ledbat = none } = SockInfo, Sample) ->
    SockInfo#network { our_ledbat = utp_ledbat:mk(Sample) };
update_our_ledbat(#network { our_ledbat = Ledbat } = SockInfo, Sample) ->
    SockInfo#network { our_ledbat = utp_ledbat:add_sample(Ledbat, Sample) }.

bump_ledbat(#network { rtt_ledbat = L,
                         our_ledbat = Our} = SockInfo) ->
    SockInfo#network { rtt_ledbat = utp_ledbat:clock_tick(L),
                         our_ledbat = utp_ledbat:clock_tick(Our)}.

-define(CONGESTION_CONTROL_TARGET, 100). % ms, perhaps we should run this in us
-define(MAX_CWND_INCREASE_BYTES_PER_RTT, 3000). % bytes
-define(MIN_WINDOW_SIZE, 3000). % bytes
congestion_control(#network { cwnd = Cwnd } = Network,
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
    Network#network {
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

