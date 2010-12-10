; -*- Mode: Markdown; -*-
; vim: filetype=none tw=76 expandtab

# ETORRENT

ETORRENT is a bittorrent client written in Erlang. The focus is on
robustness and scalability in number of torrents rather than in pure
speed. ETORRENT is mostly meant for unattended operation, where one
just specifies what files to download and gets a notification when
they are.

## Flag days

Flag days are when you need to do something to your setup

   * *2010-12-10* You will need a rebar with commit 618b292c3d84 as we
     got some fixes into rebar.
   * *2010-12-06* We now depend on riak_err. You will need to regrab
     dependencies.
   * *2010-12-02* The fast-resume-file format has been updated. You
     may have to delete your fast_resume_file though the system was
     configured to do a silent system upgrade.

## Why

ETORRENT was mostly conceived as an experiment in how easy it would be
to write a bittorrent client in Erlang. The hypothesis is that the
code will be cleaner and smaller than comparative bittorrent clients.

Note that the code is not yet battle scarred. It has not stood up to the
testing of time and as such, it will fail - sometimes in nasty ways and
maybe as a bad p2p citizen. Hence, you should put restraint in using it
unless you are able to fix eventual problems. If you've noticed any bad
behavior it is definitely a bug and should be reported as soon as possible
so we can get it away.

## Currently supported BEPs:

   * BEP 03 - The BitTorrent Protocol Specification.
   * BEP 04 - Known Number Allocations.
   * BEP 12 - Multitracker Metadata Extension.
   * BEP 23 - Tracker Returns Compact Peer Lists.

## Required software:

   * rebar - you need a working rebar installation to build etorrent.
     The rebar must have commit 618b292c3d84.
   * Erlang/OTP R13B04 or R14 - the etorrent system is written in
     Erlang and thus requires a working Erlang distribution to
     work. It may work with older versions, but has mostly been tested
     with newer versions.
   * A proper operating system (e.g., some UNIX-derivative). Windows
     support has never been tested (If you want to port, I'll be happy
     to help).

## GETTING STARTED

   0. `make deps` - Pull the relevant dependencies into *deps/*
   1. `make compile` - this compiles the source code
   2. `make rel` - this creates an embedded release in *rel/etorrent* which
      can subsequently be moved to a location at your leisure.
   3. edit `${EDITOR} rel/etorrent/etc/app.config` - there are a number of directories
      which must be set in order to make the system work.
   4. check *rel/etorrent/etc/vm.args* - Erlang args to supply
   5. If you enabled the webui, check *rel/etorrent/etc/webui.config*
   6. run `rel/etorrent/bin/etorrent console`
   7. drop a .torrent file in the watched dir and see what happens.
   8. call `etorrent:help()`. from the Erlang CLI to get a list of available
      commands.
   9. If you enabled the webui, you can try browsing to its location. By default the location is 'http://localhost:8080'.

## Setting up a development environment

When developing for etorrent, you might end up generating a new
environment quite often. So ease the configuration, the build
infrastructure support this.

   * Create a file `rel/vars/etorrent-dev_vars.config` based upon the file
     `rel/vars.config`.
   * run `make compile etorrent-dev`
   * run `make console`

Notice that we `-pa` add `../../apps/etorrent/ebin` so you can l(Mod) files
from the shell directly into the running system after having
recompiled them.

## ISSUES

Either mail them to jesper.louis.andersen@gmail.com (We are
currently lacking a mailing list) or use the issue tracker:

  http://github.com/jlouis/etorrent/issues

## Reading material for hacking Etorrent:

   - [Protocol specification - BEP0003](http://www.bittorrent.org/beps/bep_0003.html):
     This is the original protocol specification, tracked into the BEP
     process. It is worth reading because it explains the general overview
     and the precision with which the original protocol was written down.

   - [Bittorrent Enhancement Process - BEP0000](http://www.bittorrent.org/beps/bep_0000.html)
     The BEP process is an official process for adding extensions on top of
     the BitTorrent protocol. It allows implementors to mix and match the
     extensions making sense for their client and it allows people to
     discuss extensions publicly in a forum. It also provisions for the
     deprecation of certain features in the long run as they prove to be of
     less value.

   - [wiki.theory.org](http://wiki.theory.org/Main_Page)
     An alternative description of the protocol. This description is in
     general much more detailed than the BEP structure. It is worth a read
     because it acts somewhat as a historic remark and a side channel. Note
     that there are some commentary on these pages which can be disputed
     quite a lot.
