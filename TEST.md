# How to run unit tests

## Prerequisites

To run the unit tests, you currently need a set of programs installed:

* [OpenTracker](http://erdgeist.org/arts/software/opentracker/) -
  Needed for tracker operations. If you can provide an Erlang-based
  tracker, so much the better!
* [QuickCheck Mini](http://www.quviq.com/news100621.html) - The small
  version of QuviQ's QuickCheck tool. It should be somewhere in your
  Erlang path.
* [Transmission 2.21](www.transmissionbt.com) - To install this, I use
  a PPA in Ubuntu, namely `ppa:transmissionbt/ppa` use
  `add-apt-repository` to get it in.

## Performing tests

To perform all tests, run

    make distclean test

There are some important targets you can use for test cases. Note that
dependency management could be improved, so you will have to run these
manually for now:

* `distclean` - We always run tests from the *release* in *rel* so
  when you do changes, you will have to rebuild the release in
  rel. The easiest way is to distclean everything and then have the
  `test` target build the release as a dependency.

* `testclean` - The test system creates a number of files for testing
  purposes the first time it is run. This target removes these and is
  necessary if you alter the generated data already on disk.

## What tests are performed?

### EUnit

Internal tests are done with EUnit inside the modules of the etorrent
source code proper (underneath an IFDEF shield). There are both
"normal" unit tests and QuickCheck tests in there and both are run if
you execute `make eunit`.

### Common Test

Common Test is our external test framework. It uses the release build
to perform a series of does-it-work tests by trying to run the code
and requiring correctness of the tested files. Currently performed
tests:

* Start a tracker and two instances of etorrent. Seed from one
  instance to the other instance to make sure we can transfer files.

Output from Common Test are in the top-level directory `logs` by
default. Point your browser to `logs/index.html`.


