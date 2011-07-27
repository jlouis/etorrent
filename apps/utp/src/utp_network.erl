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
         handle_maxed_out_window/2,
         mk/2,

         update_reply_micro/2,

         ack_packet_rtt/3,
         update_rtt_ledbat/2,
         update_our_ledbat/2,
         update_window_maxed_out/1,
         bump_ledbat/1,

         view_zero_window/1,
         bump_window/1,
         rto/1,
         max_window_send/1,
         congestion_control/2,
         hostname_port/1,
         set_conn_id/2,
         decay_window/1,
         reset_window/1,

         handle_clock_skew/2,
         handle_estimate_exceed/1
        ]).

-export([
         send_pkt/3, send_pkt/4
        ]).

-export([update_window/6]).

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
          min_rtt = 30000000 :: integer(),
          round_trip  :: utp_rtt:t() | none,
          rtt_ledbat = none :: none | utp_ledbat:t(),
          our_ledbat = none :: none | utp_ledbat:t(),
          their_ledbat = none :: none | utp_ledbat:t(),
          %% Timeouts,
          %% --------------------
          %% Set when we update the zero window to 0 so we can reset it to 1.
          zero_window_timeout :: none | {set, reference()},

          %% Timestamps
          %% --------------------
          %% When was the window last totally full (in send direction)
          last_maxed_out_window :: integer(),
          last_window_decay :: integer()
       }).


-opaque({t,{type,{82,16},record,[{atom,{82,17},network}]},[]}).
-export_type([t/0]).

-define(INITIAL_CWND, 3000).
-define(MAX_WINDOW_DECAY, 100). % ms, we can only decay the window at this time
%% ----------------------------------------------------------------------
-spec mk(integer(),
         utp_socket:t()) -> t().
mk(PacketSize, SockInfo) ->
    Now = utp_proto:current_time_ms(),
    #network { packet_size = PacketSize,
               sock_info   = SockInfo,
               reply_micro = 0,
               round_trip = none,
               cwnd = ?INITIAL_CWND,
              
               last_maxed_out_window = Now - 300,
               last_window_decay     = Now
             }.

update_window_maxed_out(#network {} = NW) ->
    NW#network {
      last_maxed_out_window = utp_proto:current_time_ms()
     }.

update_reply_micro(#network { their_ledbat = TL } = SockInfo, RU) ->
    SockInfo#network { reply_micro = RU,
                       their_ledbat = utp_ledbat:add_sample(TL, RU) }.

handle_advertised_window(Network, #packet { win_sz = Win }) ->
    handle_advertised_window(Network, Win);
handle_advertised_window(#network{} = Network, NewWin)
  when is_integer(NewWin) ->
    Network#network { peer_advertised_window = NewWin }.

handle_window_size(#network {} = PKI, WindowSize) ->
    PKI#network { peer_advertised_window = WindowSize }.

max_window_send(#network { peer_advertised_window = AdvertisedWindow,
                           sock_info = SI,
                           cwnd = MaxSendWindow }) ->
    SendBufSz = utp_socket:send_buf_sz(SI),
    Min = lists:min([SendBufSz, AdvertisedWindow, MaxSendWindow]),
    utp_trace:trace(max_window, Min),
    Min.

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

send_pkt(AdvWin, #network { sock_info = SockInfo } = Network, Packet, conn_id_recv) ->
    send_pkt(AdvWin, Network, Packet, utp_socket:conn_id_recv(SockInfo));
send_pkt(AdvWin,
         #network { sock_info = SockInfo,
                    reply_micro = TSDiff}, Packet, ConnId)
  when is_integer(ConnId) ->
    Pkt = Packet#packet { conn_id = ConnId,
                          win_sz = AdvWin },
    utp_socket:send_pkt(SockInfo, Pkt, TSDiff).

rto(#network { round_trip = RTT }) ->
    utp_rtt:rto(RTT).

ack_packet_rtt(#network { round_trip = RTT,
                          min_rtt    = MinRTT,
                          rtt_ledbat = LedbatHistory } = NW,
               TimeSent, TimeAcked) ->
    {ok, _NewRTO, NewRTT, NewHistory} = utp_rtt:ack_packet(LedbatHistory,
                                                           RTT,
                                                           TimeSent,
                                                           TimeAcked),
    NW#network { round_trip = NewRTT,
                 min_rtt = min(TimeAcked - TimeSent, MinRTT),
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
                       their_ledbat = Their,
                       our_ledbat = Our} = SockInfo) ->
    SockInfo#network { rtt_ledbat = utp_ledbat:clock_tick(L),
                       their_ledbat = utp_ledbat:clock_tick(Their),
                       our_ledbat = utp_ledbat:clock_tick(Our)}.

-define(CONGESTION_CONTROL_TARGET, 100). % ms, perhaps we should run this in us
-define(MAX_CWND_INCREASE_BYTES_PER_RTT, 3000). % bytes
-define(MIN_WINDOW_SIZE, 3000). % bytes
congestion_control(#network {} = NW, 0) ->
    NW; %% Nothing acked, so skip maintaining the congestion control
congestion_control(#network { cwnd = Cwnd,
                              our_ledbat = OurHistory,
                              sock_info = SockInfo,
                              min_rtt = MinRtt,
                              last_maxed_out_window = LastMaxedOutTime } = Network,
                   BytesAcked) when BytesAcked > 0 ->
    case MinRtt of
        K when K > 0 ->
            ignore;
        K ->
            error({min_rtt_violated, K})
    end,
    OurDelay =
        case min(MinRtt, utp_ledbat:get_value(OurHistory)) of
            O when O >= 0 ->
                O;
            Otherwise ->
                error({our_delay_violated, Otherwise})
        end,
    utp_trace:trace(queue_delay, OurDelay),
    TargetDelay = ?CONGESTION_CONTROL_TARGET,

    TargetOffset = TargetDelay - OurDelay,
    utp_trace:trace(target_offset, TargetOffset),
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
    
    case ScaledGain =< 1 + ?MAX_CWND_INCREASE_BYTES_PER_RTT * min(BytesAcked, Cwnd)
        / max(Cwnd, BytesAcked) of
        true -> ignore;
        false ->
            error({scale_gain_violation, ScaledGain, BytesAcked, Cwnd})
    end,

    Alteration = case consider_last_maxed_window(LastMaxedOutTime) of
                     too_soon ->
                         0;
                     ok ->
                         ScaledGain
                 end,
    NewCwnd = clamp(Cwnd + Alteration, ?MIN_WINDOW_SIZE, utp_socket:send_buf_sz(SockInfo)),

    utp_trace:trace(congestion_window, NewCwnd),
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

reset_window(#network {
               packet_size = PacketSize
               } = NW) ->
    NW#network { cwnd = PacketSize }.
    
                
decay_window(#network {
                last_window_decay = LastDecay,
                cwnd = Cwnd
               } = Network) ->
    Now = utp_proto:current_time_ms(),
    case Now - LastDecay of
        K when K >= ?MAX_WINDOW_DECAY ->
            Network#network {
              last_window_decay = Now,
              cwnd = max(round(Cwnd * 0.5), ?MIN_WINDOW_SIZE)
             };
        _Otherwise ->
            Network
    end.

handle_estimate_exceed(#network { min_rtt = MinRtt,
                                  our_ledbat = Ours
                                } = NW) ->
    OurDelay = utp_ledbat:get_value(Ours),
    Diff = OurDelay - MinRtt,
    case Diff of
        K when K > 0 ->
            NW#network {
              our_ledbat = utp_ledbat:shift(Ours, K) };
        _Otherwise ->
            NW
    end.

handle_clock_skew(#network { their_ledbat = none }, NW) ->
    NW;
handle_clock_skew(#network {
                     their_ledbat = OldTheirs },
                  #network {
                    their_ledbat = Theirs,
                    our_ledbat   = Ours
                   } = NW) ->
    OldDelayBase = utp_ledbat:base_delay(OldTheirs),
    TheirBase = utp_ledbat:base_delay(Theirs),
    Diff = OldDelayBase - TheirBase,
    case utp_ledbat:compare_less(
           TheirBase,
           OldDelayBase) of
        true when Diff < 10000 ->
            NW#network { our_ledbat = utp_ledbat:shift(Ours, Diff) };
        true ->
            NW;
        false ->
            NW
    end.

handle_maxed_out_window(Messages, #network {} = NW) ->              
    case proplists:get_value(window_maxed_out, Messages) of
        true ->
            NW#network {
              last_maxed_out_window = utp_proto:current_time_ms()
             };
        undefined ->
            NW
    end.

update_window(Network, ReplyMicro, TimeAcked, Messages, TSDiff, Pkt) ->
    N6 = update_reply_micro(Network, ReplyMicro),
    N5 = handle_clock_skew(
Network,  % Deliberately the old delay base
N6),
    N4 = update_our_ledbat(N5, TSDiff),
    N3 = handle_estimate_exceed(N4),
    N2 = handle_advertised_window(N3, Pkt),
    case proplists:get_value(acked, Messages) of
        undefined ->
            N2;
        Packets when is_list(Packets) ->
            Eligible = utp_buffer:extract_rtt(Packets),
            N = lists:foldl(fun(TimeSent, Acc) ->
                                    ack_packet_rtt(Acc,
                                                   TimeSent,
                                                   TimeAcked)
                            end,
                            N2,
                            Eligible),
            BytesAcked = utp_buffer:extract_payload_size(Packets),
            congestion_control(N, BytesAcked)
    end.
