## Etorrent Makefile
## Try to keep it so simple it can be run with BSD-make as well as
## GNU-make

# Version here is used by the test suite. It should be possible to figure
# it out automatically, but for now, hardcode.
version=1.2.1

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
	rm -f test/etorrent_SUITE_data/test_file_30M.random.torrent
	rm -f test/etorrent_SUITE_data/test_file_30M.random

test: eunit common_test

## Use the ct_run in the built release
CT_RUN=rel/etorrent/erts-*/bin/ct_run
ct_src_dir := rel/etorrent/lib/etorrent-${version}/src

ct_setup: rel
	echo ${ct_src_dir}
	mkdir -p logs
# Unpack stuff.
	rm -fr rel/etorrent/lib/etorrent-*/ebin
	cd rel/etorrent/lib && unzip -o etorrent-*.ez
	mkdir -p ${ct_src_dir} && \
		cp -r apps/etorrent/src/* ${ct_src_dir}
# Run cover test

common_test: ct_setup rel
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

TABFILES=/usr/bin/env python -c \
    "import glob; print '\n'.join([file for file \
     in glob.glob('apps/*/src/*.erl') \
     if [line for line in open(file).readlines() \
     if line.startswith('\t')]])"
tabs:
	@echo "You have mutilated $(shell $(TABFILES) | wc -l) files:";
	@$(TABFILES)


.PHONY: all compile tags dialyze run tracer clean \
	 deps eunit rel xref dev console console-perf graph \
	 test testclean common_test ct_setup

%.png: %.dot
	dot -Tpng $< > $@

%.pdf: %.dot
	dot -Tpdf $< > $@

