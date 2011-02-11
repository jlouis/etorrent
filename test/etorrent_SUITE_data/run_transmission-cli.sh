#!/bin/sh

(cat && kill 0) | transmission-cli $*
