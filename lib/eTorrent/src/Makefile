ERLC=erlc

DIALYZER_FLAGS+=-Wno_return
EMULATOR=beam
DEBUG_FLAGS = -Ddebug +debug_info

MODULES=bcoding dirwatcher etorrent_app etorrent peer_communication	\
	torrent serializer check_torrent file_process file_system \
	utils metainfo torrent_manager random_source
# 	torrent_peer torrent_piecemap \
# 	tracker_delegate  pairing_heap \
# 	torrent_peer_send fs_filepiecemap \
#	connection_manager

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

