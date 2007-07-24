ERLC=erlc

DIALYZER_FLAGS+=-Wno_return
EMULATOR=beam
DEBUG_FLAGS = -Ddebug +debug_info

MODULES=bcoding dirwatcher etorrent_app etorrent peer_communication \
	torrent_control serializer check_torrent file_process file_system \
	utils metainfo torrent_manager random_source dirwatcher_sup \
	random_source_sup tracker_delegate \
	torrent_state torrent torrent_sup torrent_pool_sup \
	torrent_peer_master torrent_peer torrent_peer_send


EBIN_FILES=$(MODULES:%=../ebin/%.$(EMULATOR)) ../ebin/etorrent.app
ERLC_FLAGS+= -W $(DEBUG_FLAGS) -pa ../../eTorrent

all: $(EBIN_FILES)

dialyzer: .dialyzer.ok

.dialyzer.ok: $(MODULES:%=../ebin/%.$(EMULATOR))
	dialyzer $(DIALYZER_FLAGS) -c ../ebin
	touch .dialyzer.ok

clean:
	rm -fr $(MODULES:%=../ebin/%.$(EMULATOR))

# Targets

../ebin/%.app: %.app.src ../vsn.mk Makefile
	perl -e $(APPSCRIPT) "$(VSN)" $(MODULES) < $< > $@

../ebin/%.appup: %.appup
	cp $< $@

../ebin/%.$(EMULATOR): %.erl
	"$(ERLC)" $(ERLC_FLAGS) -o ../ebin $<

%.$(EMULATOR): %.erl
	"$(ERLC)" $(ERLC_FLAGS) $<

