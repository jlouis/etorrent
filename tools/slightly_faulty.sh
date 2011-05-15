#!/bin/sh

## Create a network where something around the 100th packet are lost.
## This is a somewhat realistic network condition and it does happen.

from=${1-127.0.0.1}
to=${2-127.0.0.1}

ipfw delete 100
ipfw delete 200
ipfw delete 300
ipfw delete 400
ipfw delete 500

ipfw add 1000 allow all from any to any

ipfw add 100 pipe 10 udp from ${from} to ${to} 3333 in
ipfw add 200 pipe 20 udp from ${to} 3333 to ${from} out
 
## Pipes starting with 10 is one way
ipfw pipe 10 config bw 10Mbit/s
ipfw pipe 10 config delay 100ms
ipfw pipe 10 config plr 0.01

## Pipes starting with 20 is the other way
ipfw pipe 20 config bw 10Mbit/s
ipfw pipe 20 config delay 100ms
ipfw pipe 20 config plr 0.01

