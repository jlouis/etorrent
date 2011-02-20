# Stuff in uTP which is not described fully

This is a loose list of stuff which is not described fully in the BEP
29 spec of the uTP protocol. It serves as help to implementors in
order to actually implement the protocol.

The code is here: https://github.com/bittorrent/libutp

* An open UDP socket acts as a TCP listen() point in the protocol.
* There are two protocol versions. 0 which is deprecated and 1 which
  is the current one. You will have to ignore all protcol data with a
  0 in the version field.
* SYN packets (st_syn) contain the `ext_bits` extension field, where
  all 8 bytes (64 bits) are set to 0.
* There is no mention of anything but the most important fields. It is
  assumed that all timestamp/rcv_window fields and so on are filled in
  by automation underneath the basic protocol.
* There are keepalives in the protocol. You keep-alive a connection by
  ack'ing (ack_no - 1).
* There are RST's in the protocol. You send an RST
* The internal state CS_CONNECTED_FULL means that we are connected but
  the outgoing buffer is full, so we can't write anymore data out.
* Naturally, you need to look up the MTU and set the packet size
  accordingly, in order to handle the question "What is the packet
  size allowed?"
* `UTP_Create()` contains constants which are not documented.
* If you get unknown NON-SYN packets with no conn, you should throw
  back an RST
* There is a concept of fast_resends, not documented
* There is a concept of closing the socket via RESET messages
* There are of course socket options, and these must be maintained.

# Good things to handle once and for all:

* `send_ack()` for sending ACK's
* `send_rst()` for sending RST's
