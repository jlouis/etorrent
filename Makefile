## Etorrent Makefile
## Try to keep it so simple it can be run with BSD-make as well as
## GNU-make

-include Makefile.config

VER=1.0

SHELL=/bin/sh
ETORRENT_LIB=.
ETORRENT_DEPS=-pa ./deps/gproc/ebin
all: compile

compile:
	./rebar compile

tags:
	cd src && $(MAKE) tags

eunit:
	./rebar eunit

dialyze: compile
	./rebar skip_deps=true dialyze

rel:
	./rebar generate

relclean:
	rm -fr rel/etorrent

run: rebar
	erl -boot start_sasl $(ERL_FLAGS) $(ETORRENT_DEPS) -pa $(ETORRENT_LIB)/ebin \
	-config $(ETORRENT_LIB)/priv/etorrent.config \
	-sname etorrent -s etorrent_app start

tracer:
	erl -boot start_sasl -pa $(ETORRENT_LIB)/ebin -noinput \
	-sname tracer -s tr client

clean:
	./rebar clean

.PHONY: all compile tags dialyze run tracer clean eunit
