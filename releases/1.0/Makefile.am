INCLUDES = ../../lib/etorrent-1.0/src

RELEASEFILES=etorrent.boot etorrent.script

etorrentdir = $(top_src)/releases/1.0
etorrent_DATA = $(RELEASEFILES)

SUFFIXES: .erl .beam .rel .script .boot
.rel.script:
	$(ERLC) -I $(INCLUDES) -b script $<
.rel.boot:
	$(ERLC) -I $(INCLUDES) -b boot $<

