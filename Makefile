## Etorrent Makefile
## Try to keep it so simple it can be run with BSD-make as well as
## GNU-make
all: compile

deps:
	rebar get-deps

compile:
	rebar compile

tags:
	cd apps/etorrent/src && $(MAKE) tags

eunit:
	rebar skip_deps=true eunit

dialyze: compile
	rebar skip_deps=true dialyze

rel:
	rebar generate

relclean:
	rm -fr rel/etorrent

clean: relclean devclean
	rebar clean

etorrent-dev: compile
	mkdir -p dev
	(cd rel && rebar generate target_dir=../dev/$@ overlay_vars=vars/$@_vars.config)

dev: etorrent-dev

devclean:
	rm -fr dev

console:
	dev/etorrent-dev/bin/etorrent console -pa ../../apps/etorrent/ebin

xref: compile
	rebar skip_deps=true xref

.PHONY: all compile tags dialyze run tracer clean eunit rel xref dev

