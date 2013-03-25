#!/bin/sh
cd `dirname $0`
ct_run -verbosity=50 -spec etorrent_test.spec -pa $PWD/ebin edit $PWD/deps/*/ebin 

