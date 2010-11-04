## Etorrent Makefile
## Try to keep it so simple it can be run with BSD-make as well as
## GNU-make
all: compile

compile:
	./rebar compile

tags:
	cd apps/etorrent/src && $(MAKE) tags

eunit:
	./rebar eunit

dialyze: compile
	./rebar skip_deps=true dialyze

rel:
	./rebar generate

relclean:
	rm -fr rel/etorrent

clean:
	./rebar clean

.PHONY: all compile tags dialyze run tracer clean eunit rel
