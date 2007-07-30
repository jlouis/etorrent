erlsrcdir = $(ERLANG_INSTALL_LIB_DIR_etorrent)/src
erlsrc_DATA = bcoding.erl check_torrent.erl dirwatcher.erl dirwatcher_sup.erl \
	etorrent_app.erl etorrent.erl file_process.erl file_system.erl \
	histogram.erl metainfo.erl peer_communication.erl serializer.erl \
	torrent_control.erl torrent_manager.erl torrent_peer.erl \
	torrent_peer_master.erl torrent_peer_send.erl torrent_pool_sup.erl \
	torrent_state.erl torrent_sup.erl tracker_delegate.erl utils.erl \
	listener.erl

erlbeamdir = $(ERLANG_INSTALL_LIB_DIR_etorrent)/ebin
erlbeam_DATA = $(erlsrc_DATA:.erl=.beam)

#erlappdir = $(erlbeamdir)
#erlapp_DATA = etorrent.app

EXTRA_DIST = $(erlsrc_DATA) $(erlapp_DATA)
CLEANFILES = $(erlbeam_DATA)

dialyzer: $(erlbeam_DATA)
	@dialyzer -c .


SUFFIXES: .erl .beam
.erl.beam:
	$(ERLC) $(ERLCFLAGS) -b beam $<
