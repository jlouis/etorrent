## Etorrent Makefile
## Try to keep it so simple it can be run with BSD-make as well as
## GNU-make

-include Makefile.config

SHELL=/bin/sh
ETORRENT_LIB=./lib/etorrent-1.0
all: libs

libs:
	cd lib && $(MAKE)

dialyzer: libs
	$(DIALYZER) -c $(ETORRENT_LIB)/ebin

run: libs
	erl -pa $(ETORRENT_LIB)/ebin -config $(ETORRENT_LIB)/priv/etorrent.config \
	-sname etorrent -s etorrent

clean:
	cd lib && $(MAKE) clean

