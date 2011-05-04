#!/bin/sh

ipfw add 1000 allow all from any to any

ipfw add 100 pipe 10 udp from 10.0.0.13 to 10.0.0.11 3333 in
ipfw add 200 pipe 20 udp from 10.0.0.11 3333 to 10.0.0.13 out
 

ipfw pipe 10 config bw 10Mbit/s
ipfw pipe 10 config delay 100ms
ipfw pipe 10 config plr 0.1

ipfw pipe 20 config bw 10Mbit/s
ipfw pipe 20 config delay 100ms
ipfw pipe 20 config plr 0.1

