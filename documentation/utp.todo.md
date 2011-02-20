* Handle the rest of the connection establish
  * Read uTP connection code, there may be some idiosyncracies :/
    - Some??? There are *numerous*. One has to really read this carefully to get an idea
      of how the protocol works.

* Handle transmit/retrieval of data
* Handle connection teardown
* Handle rcv_window
* Handle EACK reorder counts
* Handle timestamping (different from timeouts)
* Check what RBDrained is used for (timing, I think)
  - Sure! RBDrained is called whenever the receive buffer has been drained from the outside.
    In our implementation, recv/2 knows when this happens, so it should be able to update
    whenever this happens.

* Consider how to handle the tiemout stuff
  * It is definitely a thing that has to be handled by means of a timer in some way, but
    it turns out it is fairly central in the system, so it needs some thinking.


* Can we test here?
  * If so, common_test framework it, so we have a test for later
  * Test does not have to pass, just be there for later
  * Test start-up of supervisor, can probably remove some problems later on

* Handle timeouts
* Handle congestion window
  * Calculations on the window
  * Handle the window itself





