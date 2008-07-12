-include ../../Makefile.config

.PHONY: etorrent-1.0 all dialyzer

all: etorrent-1.0

tags:
	cd src && $(MAKE) tags

etorrent-1.0:
	$(ERL) -make

clean:
	rm ebin/*.beam




