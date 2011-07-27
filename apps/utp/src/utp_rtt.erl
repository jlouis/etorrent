-module(utp_rtt).

-export([
         rto/1,
         ack_packet/4
        ]).

-define(MAX_WINDOW_INCREASE, 3000).
-define(DEFAULT_RTT_TIMEOUT, 500).

-record(rtt, {rtt = 500 :: integer(),
              var = 800 :: integer()
             }).

-opaque t() :: #rtt{}.
-export_type([t/0]).

%% Every packet that is ACKed, either by falling in the range
%% (last_ack_nr, ack_nr] or by explicitly being acked by a Selective
%% ACK message, should be used to update an rtt (round trip time) and
%% rtt_var (rtt variance) measurement. last_ack_nr here is the last
%% ack_nr received on the socket before the current packet, and ack_nr
%% is the field in the currently received packet.

%% The rtt and rtt_var is only updated for packets that were sent only
%% once. This avoids problems with figuring out which packet was
%% acked, the first or the second one.

%% rtt and rtt_var are calculated by the following formula, every time
%% a packet is ACKed:

update(Estimate, RTT) ->
    utp_trace:trace(rtt_estimate, Estimate),
    case RTT of
        none ->
            case Estimate < 6000 of
                true ->
                    #rtt { rtt = round(Estimate),
                           var = round(Estimate / 2)};
                false ->
                    error({estimate_too_high, Estimate})
            end;
        #rtt { rtt = LastRTT, var = Var} ->
            Delta = LastRTT - Estimate,
            #rtt { rtt = round(LastRTT - LastRTT/8 + Estimate/8),
                   var = round(Var + (abs(Delta) - Var) / 4) }
    end.

%% The default timeout for packets associated with the socket is also
%% updated every time rtt and rtt_var is updated. It is set to:
rto(none) ->
    utp_trace:trace(rtt_rto, ?DEFAULT_RTT_TIMEOUT),
    ?DEFAULT_RTT_TIMEOUT;
rto(#rtt { rtt = RTT, var = Var}) ->
    RTO = max(RTT + Var * 4, ?DEFAULT_RTT_TIMEOUT),
    utp_trace:trace(rtt_rto, RTO),
    RTO.


%% ACKnowledge an incoming packet
ack_packet(History, RTT, TimeSent, TimeAcked) ->
    true = TimeAcked >= TimeSent,
    Estimate = utp_util:bit32(TimeAcked - TimeSent) div 1000,

    NewRTT = update(Estimate, RTT),
    NewHistory = case RTT of
                     none ->
                         History;
                     #rtt{} ->
                         utp_ledbat:add_sample(History, Estimate)
                 end,
    NewRTO = rto(NewRTT),
    {ok, NewRTO, NewRTT, NewHistory}.

%% Every time a socket sends or receives a packet, it updates its
%% timeout counter. If no packet has arrived within timeout number of
%% milliseconds from the last timeout counter reset, the socket
%% triggers a timeout. It will set its packet_size and max_window to
%% the smallest packet size (150 bytes). This allows it to send one
%% more packet, and this is how the socket gets started again if the
%% window size goes down to zero.

%% The initial timeout is set to 1000 milliseconds, and later updated
%% according to the formula above. For every packet consecutive
%% subsequent packet that times out, the timeout is doubled.
    
