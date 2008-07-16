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
	$(DIALYZER) $(DIALYZER_OPTS) --verbose -I $(ETORRENT_LIB)/include -r $(ETORRENT_LIB)/ebin

dialyzer-succ: libs
	$(DIALYZER) --verbose --succ_typings -I $(ETORRENT_LIB)/include -r $(ETORRENT_LIB)

tags:
	cd lib && $(MAKE) tags

run-create-db: libs
	erl -noinput $(ERL_FLAGS) -pa $(ETORRENT_LIB)/ebin \
	-config $(ETORRENT_LIB)/priv/etorrent.config \
	-sname etorrent -s etorrent db_create_schema

run: libs
	erl $(ERL_FLAGS) -pa $(ETORRENT_LIB)/ebin \
	-config $(ETORRENT_LIB)/priv/etorrent.config \
	-sname etorrent -s etorrent start

tracer:
	erl -pa $(ETORRENT_LIB)/ebin -noinput \
	-sname tracer -s tr client

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

