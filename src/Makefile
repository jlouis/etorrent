ERLC=erlc

DIALYZER_FLAGS+=-Wno_return
EMULATOR=beam
DEBUG_FLAGS = -Ddebug +debug_info

MODULES=bcoding dirwatcher dirwatcher_sup etorrent_app etorrent \
	filesystem peer_communication torrent torrent_manager \
	torrent_manager_sup torrent_peer torrent_piecemap \
	torrent_state tracker_delegate connection_manager

EBIN_FILES=$(MODULES:%=../ebin/%.$(EMULATOR)) ../ebin/etorrent.app
ERLC_FLAGS+= -W $(DEBUG_FLAGS) -pa ../../etorrent

all: $(EBIN_FILES)

dialyzer: .dialyzer.ok

.dialyzer.ok: $(MODULES:%=../ebin/%.$(EMULATOR))
	dialyzer $(DIALYZER_FLAGS) -c ../ebin
	touch .dialyzer.ok

# Targets

../ebin/%.app: %.app.src ../vsn.mk Makefile
	perl -e $(APPSCRIPT) "$(VSN)" $(MODULES) < $< > $@

../ebin/%.appup: %.appup
	cp $< $@

../ebin/%.$(EMULATOR): %.erl
	"$(ERLC)" $(ERLC_FLAGS) -o ../ebin $<

%.$(EMULATOR): %.erl
	"$(ERLC)" $(ERLC_FLAGS) $<
