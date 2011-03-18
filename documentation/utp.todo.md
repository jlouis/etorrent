### "Real" TODO:

* Try to transfer data on the UTP socket, don't close the socket again.
* Move lots of data, testing the window code as it is right now.
* Window alterations
* Retransmit timers
* Packet Timestamping

* Write code for socket teardown.
  ** Essentially, you just tag an st_fin flag on top of the last/next packet going out
     on the socket, and move yourself into the fin_sent state.
  ** There are a bunch of serious timeout stuff you need to handle to make this work as well,
     so we need to get a grip on the other parts first.
* Test closing the socket as well.

* Handle outgoing timestamping
* Window Size incoming (SKIP THIS FOR NOW, we can just use the incoming advertised window)
  * Study this.
  * Window is changed in the selective ack code, and in LEDBAT Congestion Control
  * max_window is our maximal window, which can be manipulated
    window_decay is one place
    reset on timeout is a second
    in LEDBAT CControl is a third
    initialized to the packet size when starting out
    maybe_decay_win adjusts the window, based on the selective ack information

  * max_window_user is the other ends max_window (call it max_window_peer)
    It is *essentially* what we get from the other end!

* Timestamp handling
* Close down
* Timeout close down
* Split utp_pkt into its constituents.
* Retransmit, Ack timeouts.
* Fast timeout/retransmit handling is not done yet.
* Selective ACK is not done yet.
* SendQuotas

* Handle incoming timestamping
  * We currently do not do anything with incoming packets. We should.

### "Old" TODO:

* Handle the rest of the connection establish
  * Read uTP connection code, there may be some idiosyncracies :/
    - Some??? There are *numerous*. One has to really read this carefully to get an idea
      of how the protocol works.

* Go Through utp.cpp and add missing routines here
  * send_data()
  * is_writable() -- Perhaps not do this
  * flush_packets()
  * write_outgoing_packet()
  * update_send_quota()
  * check_timeouts() -- Definitely change!
  * ack_packet()
  * selective_ack_bytes()
  * selective_ack()
  * apply_ledbat_ccontrol()
  * get_packet_size() -- Fix from bad default
  * UTP_ProcessIncoming() -- Definitely change!
  * UTP_* add here!
* Implement send_ack()
* Implement timing in send()
* Handle transmit/retrieval of data
* Handle connection teardown
* Handle rcv_window
* Handle EACK reorder counts
* Handle timestamping (different from timeouts)
* Check what RBDrained is used for (timing, I think)
  - Sure! RBDrained is called whenever the receive buffer has been drained from the outside.
    In our implementation, recv/2 knows when this happens, so it should be able to update
    whenever this happens.

* Consider how to handle the timeout stuff
  * It is definitely a thing that has to be handled by means of a timer in some way, but
    it turns out it is fairly central in the system, so it needs some thinking.
  - We will use a lot of erlang:send_after/3 calls :)

* Can we test here?
  * If so, common_test framework it, so we have a test for later
  * Test does not have to pass, just be there for later
  * Test start-up of supervisor, can probably remove some problems later on
  - Postpone this a bit. The protocol internals will take some time before they will work

* Handle timeouts
* Handle congestion window
  * Calculations on the window
  * Handle the window itself

