#!/bin/sh
#
# Traffic-shape a test network

tc qdisc replace dev lo root netem \
    delay 100ms 20ms distribution normal \
    reorder 25% 50% \
    loss 0.3% 25% \
    duplicate 1%

