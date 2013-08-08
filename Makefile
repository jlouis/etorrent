### Etorrent Makefile
PROJECT = etorrent

## Version here is used by the test suite. It should be possible to figure
## it out automatically, but for now, hardcode.
version=1.2.1

dev-release: deps
	relx -o dev/$(PROJECT) -c relx-dev.config

release: deps
	relx -o rel/$(PROJECT)

clean-release:
	rm -fr rel/$(PROJECT)

DEPS = etorrent_core
dep_etorrent_core = git://github.com/jlouis/etorrent_core.git master

include erlang.mk

console:
	dev/etorrent/bin/etorrent console \
		-pa ../../deps/*/ebin


