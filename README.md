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

## Maturity

The code is at this point somewhat mature. It has been used in several
scenarios with a good host of different clients and trackers. The code
base is not known to act as a bad p2p citizen, although it may be
possible that it is.

The most important missing link currently is that only a few users
have been testing it - so there may still be bugs in the code. The
`master` branch has been quite stable for months now however, so it is
time to get some more users for testing. Please report any bugs,
especially if the client behaves badly.

## Currently supported BEPs:

   * BEP 03 - The BitTorrent Protocol Specification.
   * BEP 04 - Known Number Allocations.
   * BEP 05 - DHT Protocol
   * BEP 10 - Extension Protocol
   * BEP 12 - Multitracker Metadata Extension.
   * BEP 15 - UDP Tracker Protocol
   * BEP 23 - Tracker Returns Compact Peer Lists.

## Required software:

   * rebar - you need a working rebar installation to build etorrent.
     The rebar must have commit 618b292c3d84. It is known that rebar
     version `rebar version: 2 date: 20110310_155239 vcs: git 2e1b4da`
     works, and later versions probably will too.
   * Erlang/OTP R13B04 or R14 - the etorrent system is written in
     Erlang and thus requires a working Erlang distribution to
     work. It may work with older versions, but has mostly been tested
     with newer versions.

     If you have the option, running on R14B02 is preferred. The
     developers are usually running on fairly recent Erlang/OTP
     releases, so you have much better chances with these systems.
   * A UNIX-derivative or Windows as the operating system
     Support has been tested by mulander and is reported to work with
     some manual labor. For details see the Windows getting started section.

## GETTING STARTED

   0. `make deps` - Pull the relevant dependencies into *deps/*
   1. `make compile` - this compiles the source code
   2. `make rel` - this creates an embedded release in *rel/etorrent* which
      can subsequently be moved to a location at your leisure.
   3. edit `${EDITOR} rel/etorrent/etc/app.config` - there are a number of directories
      which must be set in order to make the system work.
   4. check `${EDITOR} rel/etorrent/etc/vm.args` - Erlang args to supply
   5. be sure to protect the erlang cookie or anybody can connect to
      your erlang system! See the Erlang user manual in [distributed operation](http://www.erlang.org/doc/reference_manual/distributed.html)
   6. run `rel/etorrent/bin/etorrent console`
   7. drop a .torrent file in the watched dir and see what happens.
   8. call `etorrent:help()`. from the Erlang CLI to get a list of available
      commands.
   9. If you enabled the webui, you can try browsing to its location. By default the location is 'http://localhost:8080'.

## GETTING STARTED (Windows)
   0. Obviously get and install erlang from erlang.org. This process was tested with R14B01 release.
      You may want to add the bin directory to your PATH in order to reduce the length of the commands you will enter later on.
   1. Install [msysgit](http://code.google.com/p/msysgit/). Tested with [1.7.3.1.msysgit.0](http://code.google.com/p/msysgit/downloads/detail?name=Git-1.7.3.1-preview20101002.exe&can=2&q=).
   2. Install [Win32 OpenSSL](http://www.slproweb.com/products/Win32OpenSSL.html).
      The installer hang on me midway through the process but the libs were properly copied to C:\Windows\system32.
   3. Confirm that your crypto works correctly by running `crypto:start().` from an erlang shell (Start->Erlang OTP R14B01->Erlang).
      The shell should respond with `ok`. If you get an error then your openssl libraries are still missing.
   4. Open up a git bash shell and cd to a directory you want to work in.
   5. Clone the rebar repository `git clone https://github.com/basho/rebar.git`
   6. From a regular cmd.exe shell `cd rebar`. Now if you added the erlang bin directory to your PATH then you can simply run `bootstrap.bat`.
      If you didn't add Erlang's bin to your path then issue the following command:
      
      `"C:\Program Files\erl5.8.2\bin\escript.exe" bootstrap`

      Adjust the path to your Erlang installation directory. From now on, use this invocation for escript.exe and erl.exe. I'll assume it's on PATH.
      You should now have a `rebar` file created. If you have Erlangs bin dir on your PATH then you may want to also add the rebar directory to your
      PATH. This will allow you to use the rebar.bat script which will also reduce the amount of typing you will have to do.
   7. Clone etorrent and copy the `rebar` file into it (unless you have it on path).
   8. Now, we need to satisfy the dependencies. This should be done by rebar itself but I couldn't get it to work correctly with git.
      This point describes how to do it manually.
      
      `mkdir deps` # this is where rebar will look for etorrent dependencies
      
      `escript.exe rebar check-deps` # this will give you a list of the missing dependencies and their git repos.
      
      For each dependency reported by check-deps perform the following command in a git bash shell (be sure to be in the etorrent directory)
      
      `git clone git://path_to_repo/name.git deps/name`
      
      Be sure to run `escript.exe rebar check-deps` after cloning each additional repo as new dependencies might be added by them.
      
      For the time of this writing (2011-02-13) I had to clone the following repositories:
      
      `git clone git://github.com/esl/gproc.git deps/gproc`
      
      `git clone git://github.com/esl/edown.git deps/edown`
      
      `git clone git://github.com/basho/riak_err.git deps/riak_err`
   9. `escript.exe rebar compile` to compile the application from a cmd.exe prompt.
  10. `escript.exe rebar generate` this creates an embedded release in *rel/etorrent* which
       can subsequently be moved to a location at your leisure. This command may take some time so be patient.
  11. Edit `rel/etorrent/etc/app.config` - there are a number of directories which must be set in order to make the system work.
      Be sure each directory exists before starting etorrent. You also have to change all paths starting with `/` (ie. `/var/lib...`).
      When setting paths use forward slashes. For example `{dir, "D:/etorrent/torrents"},`.
  12. Check `rel/etorrent/etc/vm.args` - Erlang args to supply
  13. Be sure to protect the erlang cookie or anybody can connect to
      your erlang system! See the Erlang user manual in [distributed operation](http://www.erlang.org/doc/reference_manual/distributed.html)
  14. We can't run the etorrent script because it's written in bash. So in order to start ettorent cd from a cmd.exe shell into the `rel\etorrent`
      directory. And perform the following command
      
      `erts-5.8.2\bin\erl.exe -boot release\1.2.1\etorrent -embedded -config etc\app.config -args_file etc\vm.args`
      
      Be sure to substitute the version number in the release path to the current etorrent release version. Do the same for the erts version.
      Allow port communication when/if the Windows firewall asks for it.
  15. drop a .torrent file in the watched dir and see what happens.
  16. call `etorrent:help()`. from the Erlang CLI to get a list of available commands.
  17. If you enabled the webui, you can try browsing to its location. By default the location is 'http://localhost:8080'.

## Testing etorrent

Read the document [etorrent/TEST.md](/jlouis/etorrent/tree/master/TEST.md)
for how to run tests of the system.

## Troubleshooting

If the above commands doesn't work, we want to hear about it. This is
a list of known problems:

   * General: Many distributions are insane and pack erlang in split
     packages, so each part of erlang is in its own package. This
     *always* leads to build problems due to missing stuff. Be sure
     you have all relevant packages installed. And when you find which
     packages are needed, please send a patch to this file for the
     distribution and version so we can keep it up-to-date.

   * Ubuntu 10.10: Ubuntu has a symlink `/usr/lib/erlang/man ->
   /usr/share/man`. This is insane and generates problems when
   building a release (spec errors on missing files if a symlink
   points to nowhere). The easiest fix is to remove the man symlink
   from `/usr/lib/erlang`. A way better fix is to install a recent
   Erlang/OTP yourself and use **Begone(tm)** on the supplied version.

### Installing Erlang

I (jlouis@) use the following commands to install Erlang:

* Install *stow*, `sudo aptitude install stow`
* Execute `sudo aptitude build-dep erlang` to pull in all build
dependencies we need.
* Execute `git clone git://github.com/erlang/otp.git`
* Get into the directory and fire away `git checkout dev && ./otp_build autoconf`
* `./configure --prefix=/usr/local/stow/otp-dev-$(date +%Y%m%d)`
* `make; make docs`
* `make install install-docs`

And then I enable it in stow:

    cd /usr/local/stow && stow otp-dev-$(date +%Y%m%d)

## QUESTIONS??

You can either mail them to `jesper.louis.andersen@gmail.com` or you
can come by on IRC #etorrent/freenode and ask.

# Development

## PATCHES

To submit patches, we have documentation in `documentation/git.md`,
giving tips to patch submitters.

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

## Documentation

Read the HACKING.md file in this directory. For how the git repository
is worked, see `documentation/git.md`.

## ISSUES

Either mail them to `jesper.louis.andersen@gmail.com` (We are
currently lacking a mailing list) or use the [issue tracker](http://github.com/jlouis/etorrent/issues)

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
