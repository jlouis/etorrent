## Etorrent Makefile
## Try to keep it so simple it can be run with BSD-make as well as
## GNU-make

REPO=etorrent

# Version here is used by the test suite. It should be possible to figure
# it out automatically, but for now, hardcode.
version=1.2.1

all: compile

get-deps:
	rebar get-deps

compile:
	rebar compile

tags:
	cd apps/etorrent/src && $(MAKE) tags

eunit:
	rebar skip_deps=true eunit

doc:
	rebar skip_deps=true doc

APPS = kernel stdlib sasl erts ssl tools os_mon runtime_tools crypto inets \
	xmerl webtool snmp public_key mnesia eunit syntax_tools compiler
COMBO_PLT = $(HOME)/.$(REPO)_combo_dialyzer_plt

check_plt: compile
	dialyzer --check_plt --plt $(COMBO_PLT) --apps $(APPS) \
		deps/*/ebin

build_plt: compile
	dialyzer --build_plt --output_plt $(COMBO_PLT) --apps $(APPS) \
		deps/bullet/ebin\
		deps/cascadae/ebin\
		deps/cowboy/ebin\
		deps/etorrent_core/ebin\
		deps/gproc/ebin\
		deps/jsx/ebin\
		deps/lager/ebin\
		deps/meck/ebin\
		deps/proper/ebin\
		deps/upnp/ebin\
		deps/rlimit/ebin

dialyzer:
	@echo
	@echo Use "'make check_plt'" to check PLT prior to using this target.
	@echo Use "'make build_plt'" to build PLT prior to using this target.
	@echo
	@sleep 1
	dialyzer --fullpath --plt $(COMBO_PLT) \
		deps/etorrent_core/ebin | \
			grep -F -v -f ./dialyzer.ignore-warnings

clean_plt:
	@echo
	@echo "Are you sure?  It takes about 1/2 hour to re-build."
	@echo Deleting $(COMBO_PLT) in 5 seconds.
	@echo
	sleep 5
	rm $(COMBO_PLT)

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
	(cd rel \
	&& rebar generate target_dir=../dev/$@ overlay_vars=dev.config)

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
	rm -fr rel/etorrent/lib/etorrent_core-*/ebin
	cd rel/etorrent/lib && unzip -o etorrent_core-*.ez
	mkdir -p ${ct_src_dir} && \
		cp -r deps/etorrent_core/src/* ${ct_src_dir}
# Run cover test
common_test: ct_setup rel
	${CT_RUN} -spec etorrent_test.spec

console:
	dev/etorrent-dev/bin/etorrent console \
		-pa ../../deps/etorrent_core/ebin

remsh:
	erl -name 'foo@127.0.0.1' \
	-remsh 'etorrent@127.0.0.1' -setcookie etorrent

console-perf:
	perf record -- dev/etorrent-dev/bin/etorrent console\
	-pa ../../apps/etorrent/ebin

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


.PHONY: all compile tags dialyzer run tracer clean \
	 deps eunit rel xref dev console console-perf graph \
	 test testclean common_test ct_setup build_plt check_plt clean_plt

%.png: %.dot
	dot -Tpng $< > $@

%.pdf: %.dot
	dot -Tpdf $< > $@

