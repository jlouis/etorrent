#!/bin/sh

from="$1"
to="$2"

ipfw add 1000 allow all from any to any

ipfw add 100 pipe 10 udp from ${from} to ${to} 3333 in
ipfw add 200 pipe 20 udp from ${to} 3333 to ${from} out
 
## Pipes starting with 10 is one way
ipfw pipe 10 config bw 10Mbit/s
ipfw pipe 10 config delay 100ms
ipfw pipe 10 config plr 0.1

## Pipes starting with 20 is the other way
ipfw pipe 20 config bw 10Mbit/s
ipfw pipe 20 config delay 100ms
ipfw pipe 20 config plr 0.1

