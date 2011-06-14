-module(utp_rtt).

-export([
         rtt_update/2,
         rtt_rto/1,
         rtt_ack_packet/4
        ]).

-define(MAX_WINDOW_INCREASE, 3000).
-define(DEFAULT_RTT_TIMEOUT, 500).

-record(rtt, {rtt :: integer(),
              var :: integer()
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

rtt_update(Estimate, RTT) ->
    case RTT of
        none ->
            true = Estimate < 6000,
            #rtt { rtt = round(Estimate),
                   var = round(Estimate / 2)};
        #rtt { rtt = LastRTT, var = Var} ->
            Delta = LastRTT - Estimate,
            #rtt { rtt = round(LastRTT - LastRTT/8 + Estimate/8),
                   var = round(Var + (abs(Delta) - Var) / 4) }
    end.

%% The default timeout for packets associated with the socket is also
%% updated every time rtt and rtt_var is updated. It is set to:

rtt_rto(#rtt { rtt = RTT, var = Var}) ->
    max(RTT + Var * 4, ?DEFAULT_RTT_TIMEOUT).

%% ACKnowledge an incoming packet
rtt_ack_packet(History, RTT, TimeSent, TimeAcked) ->
    true = TimeAcked >= TimeSent,
    Estimate = TimeAcked - TimeSent,

    NewRTT = rtt_update(Estimate, RTT),
    NewHistory = case RTT of
                     none ->
                         History;
                     #rtt{} ->
                         utp_ledbat:add_sample(History, Estimate)
                 end,
    NewRTO = rtt_rto(NewRTT),
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
    

