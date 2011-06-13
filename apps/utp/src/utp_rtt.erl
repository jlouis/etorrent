-module(utp_rtt).

-export([
         rtt_update/3,
         rtt_timeout/2
        ]).

-define(DEFAULT_RTT_TIMEOUT, 500).

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

rtt_update(RTT, PacketRTT, RTTVar) ->
    Delta = RTT - PacketRTT,
    [{rtt_var, RTTVar + ((abs(Delta) - RTTVar) / 4)},
     {rtt, RTT + (PacketRTT - RTT) / 8}].

%% The default timeout for packets associated with the socket is also
%% updated every time rtt and rtt_var is updated. It is set to:

rtt_timeout(RTT, RTT_Var) ->
    max(?DEFAULT_RTT_TIMEOUT, RTT + RTT_Var * 4).

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

