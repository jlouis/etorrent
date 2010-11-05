## Etorrent Makefile
## Try to keep it so simple it can be run with BSD-make as well as
## GNU-make
all: compile

compile:
	./rebar compile

tags:
	cd apps/etorrent/src && $(MAKE) tags

eunit:
	./rebar skip_deps=true eunit

dialyze: compile
	./rebar skip_deps=true dialyze

rel:
	./rebar generate

relclean:
	rm -fr rel/etorrent

clean:
	./rebar clean

jlouis-dev:
	mkdir -p dev
	(cd rel && ../rebar generate target_dir=../dev/$@ overlay_vars=vars/$@_vars.config)

devclean:
	rm -fr dev

jlouis-cons:
	dev/jlouis-dev/bin/etorrent console

console: clean relclean compile rel
	cp ~/app.config rel/etorrent/etc
	rel/etorrent/bin/etorrent console

.PHONY: all compile tags dialyze run tracer clean eunit rel
