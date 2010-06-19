# ETORRENT

ETORRENT is a bittorrent client written in Erlang. The focus is on
robustness and scalability in number of torrents rather than in pure
speed. ETORRENT is mostly meant for unattended operation, where one
just specifies what files to download and gets a notification when
they are.

ETORRENT was mostly conceived as an experiment in how easy it would be
to write a bittorrent client in Erlang. The hypothesis is that the
code will be cleaner and smaller than comparative bittorrent clients.

Note that the code is not yet battle scarred. It has not stood up to the
testing of time and as such, it will fail - sometimes in nasty ways and
maybe as a bad p2p citizen. Hence, you should put restraint in using it
unless you are able to fix eventual problems. If you've noticed any bad
behavior it is definitely a bug and should be reported as soon as possible
so we can get it away.

Currently supported BEPs:

   * BEP 03 - The BitTorrent Protocol Specification.
   * BEP 04 - Known Number Allocations.
   * BEP 23 - Tracker Returns Compact Peer Lists.

## GETTING STARTED WITHOUT INSTALLING

  1. Check Makefile.config for the right configuration options
  2. edit the file 'priv/etorrent.config'. Use the example 'priv/etorrent.config.example' as a start.
  3. 'rebar compile'
  4. 'make run'
  5. drop a .torrent file in the watched dir and see what happens.
  6. call etorrent:help(). from the Erlang CLI to get a list of available
     commands.
  7. If you enabled the webui, you can try browsing to its location. By default the location is 'http://localhost:8080'.

## GETTING STARTED WITH INSTALLING

  1. edit 'Makefile.config' to suit your liking.
  2. 'rebar compile'
  3. 'rebar generate'
  4. You should now have a standalone embedded node in the 'rel' directory.

## ISSUES

Either mail them to jesper.louis.andersen@gmail.com (We are
currently lacking a mailing list) or use the issue tracker:

  http://github.com/jlouis/etorrent/issues
