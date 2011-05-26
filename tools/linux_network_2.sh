#!/bin/sh
#
# Traffic-shape a test network

tc qdisc replace dev lo root netem \
    delay 10ms 5ms distribution normal \
    reorder 25% 50% \
    loss 1.5% 25% \
    duplicate 3%

