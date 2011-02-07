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

doc:
	rebar skip_deps=true doc

dialyze: compile
	rebar skip_deps=true dialyze

typer:
	typer --plt ~/.etorrent_dialyzer_plt -r apps -I apps/etorrent/include

rel: compile rel/etorrent

rel/etorrent:
	rebar generate

relclean:
	rm -fr rel/etorrent

clean:
	rebar clean
	rm -f depgraph.dot depgraph.png depgraph.pdf

distclean: clean relclean devclean

etorrent-dev: compile
	mkdir -p dev
	(cd rel && rebar generate target_dir=../dev/$@ overlay_vars=vars/$@_vars.config)

dev: etorrent-dev

devclean:
	rm -fr dev

testclean:
	rm -f test/etorrent_SUITE_data/test_file_30M.random

test: eunit common_test

## Use the ct_run in the built release
CT_RUN=rel/etorrent/erts-*/bin/ct_run

common_test: rel
	mkdir -p logs
	${CT_RUN} -spec etorrent_test.spec

console:
	dev/etorrent-dev/bin/etorrent console \
		-pa ../../apps/etorrent/ebin \
		-pa ../../deps/riak_err/ebin

remsh:
	erl -name 'foo@127.0.0.1' -remsh 'etorrent@127.0.0.1' -setcookie etorrent

console-perf:
	perf record -- dev/etorrent-dev/bin/etorrent console -pa ../../apps/etorrent/ebin

xref: compile
	rebar skip_deps=true xref

graph: depgraph.png depgraph.pdf

depgraph.dot: compile
	./tools/graph apps/etorrent/ebin $@ etorrent


.PHONY: all compile tags dialyze run tracer clean \
	 deps eunit rel xref dev console console-perf graph \
	 test testclean common_test

%.png: %.dot
	dot -Tpng $< > $@

%.pdf: %.dot
	dot -Tpdf $< > $@

