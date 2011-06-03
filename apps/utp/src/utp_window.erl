-module(utp_window).

-include("utp.hrl").

-export([
         handle_window_size/2,
         handle_advertised_window/2,
         mk/0,

         view_zero_window/1,
         bump_window/1,
         rto/1,
         max_window_send/2,

         update_ledbat/2,
         bump_ledbat/1
        ]).

-record(pkt_window, {
          %% Size of the window the Peer advertises to us.
          peer_advertised_window = 4096 :: integer(),

          %% The current window size in the send direction, in bytes.
          cur_window :: integer(),
          %% Maximal window size int the send direction, in bytes.
          max_send_window :: integer(),

          %% Timeouts,
          %% --------------------
          %% Set when we update the zero window to 0 so we can reset it to 1.
          zero_window_timeout :: none | {set, reference()},
          rto = 3000 :: integer(), % Retransmit timeout default

          %% Timestamps
          %% --------------------
          %% When was the window last totally full (in send direction)
          last_maxed_out_window :: integer(),

          ledbat = none :: none | utp_ledbat:t()
         }).


-opaque t() :: #pkt_window{}.
-export_type([t/0]).

%% ----------------------------------------------------------------------
-spec mk() -> t().
mk() ->
    #pkt_window { }.

handle_advertised_window(PKW, #packet { win_sz = Win }) ->
    handle_advertised_window(PKW, Win);
handle_advertised_window(#pkt_window {} = PKWin, NewWin) when is_integer(NewWin) ->
    PKWin#pkt_window { peer_advertised_window = NewWin }.

handle_window_size(#pkt_window {} = PKI, WindowSize) ->
    PKI#pkt_window { peer_advertised_window = WindowSize }.

max_window_send(SendBufSz,
                #pkt_window { peer_advertised_window = AdvertisedWindow,
                              max_send_window = MaxSendWindow }) ->
    lists:min([SendBufSz, AdvertisedWindow, MaxSendWindow]).

view_zero_window(#pkt_window { peer_advertised_window = N }) when N > 0 ->
    ok; % There is no reason to update the window
view_zero_window(#pkt_window { peer_advertised_window = 0 }) ->
    zero.

bump_window(#pkt_window {} = Win) ->
    PacketSize = utp_socket:packet_size(todo),
    Win#pkt_window {
      peer_advertised_window = PacketSize
     }.

rto(#pkt_window { rto = RTO }) ->
    RTO.

update_ledbat(#pkt_window { ledbat = none } = Window, Sample) ->
    Window#pkt_window { ledbat = utp_ledbat:mk(Sample) };
update_ledbat(#pkt_window { ledbat = Ledbat } = Window, Sample) ->
    Window#pkt_window { ledbat = utp_ledbat:add_sample(Ledbat, Sample) }.

bump_ledbat(#pkt_window { ledbat = L } = Window) ->
    Window#pkt_window { ledbat = utp_ledbat:clock_tick(L) }.
    
