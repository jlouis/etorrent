## Etorrent Makefile
## Try to keep it so simple it can be run with BSD-make as well as
## GNU-make

-include Makefile.config

VER=1.0

SHELL=/bin/sh
ETORRENT_LIB=./lib/etorrent-1.0
all: libs

libs:
	cd lib && $(MAKE)

dialyzer: libs
	$(DIALYZER) -c $(ETORRENT_LIB)/ebin

run: libs
	erl $(ERL_FLAGS) -pa $(ETORRENT_LIB)/ebin \
	-config $(ETORRENT_LIB)/priv/etorrent.config \
	-sname etorrent -s etorrent

clean:
	cd lib && $(MAKE) clean

install:
	mkdir -p $(RELEASE_PREFIX)/lib/etorrent-$(VER)
	for i in src ebin include priv; do \
		cp -r $(ETORRENT_LIB)/$$i $(RELEASE_PREFIX)/lib/etorrent-$(VER) ; \
	done

	mkdir -p $(BIN_PREFIX)
	sed -e "s|%%%BEAMDIR%%%|$(RELEASE_PREFIX)/lib/etorrent-$(VER)/ebin|;" \
	    -e "s|%%%CONFIGFILE%%%|$(RELEASE_PREFIX)/lib/etorrent-$(VER)/priv/etorrent.config|;" \
	    -e "s|%%%ERL_FLAGS%%%|\"$(ERL_FLAGS)\"|" < ./bin/etorrentctl.in > $(BIN_PREFIX)/etorrentctl
	chmod +x $(BIN_PREFIX)/etorrentctl

