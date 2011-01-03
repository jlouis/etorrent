# Introduction

This document describes an architectural overview of the Etorrent
application. It is meant for hackers to be used for doing changes on
the application and bootstrap them to be able to do changes faster.

The document is currently dated:

    2010-12-22

And information herein might need a review if we are much after this
date because the code is in constant motion. This is a warning. Ask
for an update if it is too old!

# Tips and tricks used throughout the code base

There are a couple of tricks which are used again and again in the
code base. These could be called the "Design Patterns" of Erlang/OTP.

## Monitoring deaths

A very commonly used scheme is where we have a bookkeeping process *B*
and a client *C*. Usually the bookkeeping process is used because it
can globalize information, the current download rate of processes
say. So *C* stores its rates in an ETS table governed
by *B*. The problem is now: What if *C* dies? *C* itself can't clean
up since it is in an unknown state.

The trick we use is to monitor *C* from *B*. Then, when a `'DOWN'`
message comes to *B* it uses it to clean up after *C*. The trick is
quite simple, but since it is used throughout the code in many places,
I wanted to cover it here.

## Init with a timeout of 0

Some processes have a timeout of 0 in their `init/1` callback. This
means that they time out right away as soon as they are initialized
and can do more work there. Remember, when a newly spawned process
(the spawnee) is running `init` the spawner (calling spawn_link) will
be blocked. A timeout of 0 gets around that problem.

This means you can spawn a `gen_server` and then politely ask it to
enter a loop based upon incoming events right away. You don't have to
explicitly tell it with a message to do some processing first which
lowers the expectations of the caller. *The spawn of a process is its
initialization* the idiom seems to be, but I will refrain from calling
it SPII.

## When a controlling process dies, so does its resource

If we have an open port or a created ETS table, the crash or stop of
the controlling process will also remove the ETS table or end the open
port. We use this throughout etorrent to avoid having to trap exits
all over the place and make sure that processes are closed down. It is
quite confusing for a newcomer though, hence it is mentioned here.

## The ETS table plus governor

A process is spawned to create and govern an ETS table. The idea is
that lookups doesn't touch the governor at all, but it is used to
monitor the users of the table - and it is used to serialize access to
the table when needed.

Suppose for instance that something must only happen once. By sending
a call to the governor, we can serialize the request and thus make
sure only one process will initialize the thing.

## Message is a process

(Stolen from a stackoverflow answer by jlouis@)

Let `M` be an Erlang term() which is a *message* we send around in the
system. One obvious way to handle `M` is to build a pipeline of
processes and queues. `M` is processed by the first worker in the
pipeline and then sent on to the next queue. It is then picked up by
the next worker process, processed again and put into a queue. And so
on until the message has been fully processed.

The perhaps not-so-obvious way is to define a process `P` and then
hand `M` to `P`. We will notate it as `P(M)`. Now the message itself
is a *process* and not a piece of *data*. `P` will do the same job
that the workers did in the queue-solution but it won't have to pay
the overhead of sticking the `M` back into queues and pick it off
again and so on. When the processing `P(M)` is done, the process will
simply end its life. If handed another message `M'` we will simply
spawn `P(M')` and let it handle that message concurrently. If we get a
set of processes, we will do `[P(M) || M <- Set]` and so on.

If `P` needs to do synchronization or messaging, it can do so without
having to "impersonate" the message, since it *is* the
message. Contrast with the worker-queue approach where a worker has to
take responsibility for a message that comes along it. If `P` has an
error, only the message `P(M)` affected by the error will
crash. Again, contrast with the worker-queue approach where a crash in
the pipeline may affect other messages (mostly if the pipeline is
badly designed).

So the trick in conclusion: Turn a message into a process that
*becomes* the message.

The idiom is 'One Process per Message' and is quite common in
Erlang. The price and overhead of making a new process is low enough
that this works. You may want some kind of overload protection should
you use the idea however. The reason is that you probably want to put
a limit to the amount of concurrent requests so you *control* the load
of the system rather than blindly let it destroy your servers. One
such implementation is *Jobs*, created by Erlang Solutions, see the
[jobs](https://github.com/esl/jobs) repository at github. Ulf Wiger is
presenting it at
[Erlang Factory Lite (jobs talk)](http://www.erlang-factory.com/conference/ErlangFactoryLiteLA/speakers/UlfWiger).

As Ulf hints in the talk, we will usually do some preprocessing
outside `P` to parse the message and internalize it to the Erlang
system. But as soon as possible we will make the message `M` into a
*job* by wrapping it in a process (`P(M)`). Thus we get the benefits
of the Erlang Scheduler right away.

There is another important ramification of this choice: If processing
takes a long time for a message, then the preemptive scheduler of
Erlang will ensure that messages with less processing needs still get
handled quickly. If you have a limited amount of worker queues, you
may end up with many of them being clogged, hampering the throughput
of the system.

# Dependencies

Etorrent currently use two dependencies:

### Gproc

GProc is a process table written by Ulf Wiger at Erlang Solutions. It
basically maintains a lookup table in ETS for processes. We use this
throughout etorrent whenever we want to get hold of a process which is
not "close" in the supervisor tree. We do this because it is way
easier than to propagate around process ids all the time. GProc has a
distributed component which we are not using at all.

### riak_err

The built-in SASL error logger of Erlang has problems when the
messages it tries to log goes beyond a certain size. It manifests
itself by the beam process taking up several gigabytes of memory. The
[riak_err](http://github.com/basho/riak_err) application built by
Basho technologies remedies this problem. It is configured with a
maximal size and will gracefully limit the output so these kinds of
errors does not occur.

The downside is less configurability. Most notably, etorrent is quite
spammy in its main console. One way around it is to connect to
etorrent via another node,

    erl -name 'foo@127.0.0.1' \
        -remsh 'etorrent@127.0.0.1' \
	-setcookie etorrent

and then carry out commands from there.

# General layout of the source code

This is the hierarchy:

   * [/apps/](https://github.com/jlouis/etorrent/tree/master/apps) - Container for applications
   * [/apps/etorrent/](https://github.com/jlouis/etorrent/tree/master/apps/etorrent) - The etorrent application
   * /apps/etorrent/doc/ - edoc-generated output for the etorrent app.
   * /apps/etorrent/ebin - Where .beam files are compiled to
   * [/apps/etorrent/include](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/include) - include (.hrl) files
   * [/apps/etorrent/priv](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/priv) - private data for the app.
   * [/apps/etorrent/src](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/src) - main source code

The above should not pose any trouble with a seasoned or beginning
erlang hacker.

   * [/apps/etorrent/priv/webui/htdocs/](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/priv/webui/htdocs)

This directory contains the data used by the Web UI system. It is
basically dumping ground for Javascript code and anything static we
want to present to a user of the applications web interface.

   * [/deps/](https://github.com/jlouis/etorrent/tree/master/deps) - dependencies are downloaded to here
   * /dev/ - when you generate development embedded VMs they go here
   * [/documentation/](https://github.com/jlouis/etorrent/tree/master/documentation) - haphazard general documentation about etorrent
   * [/tools/](https://github.com/jlouis/etorrent/tree/master/tools) - small tools for manipulating and developing the source
   * [/rel/](https://github.com/jlouis/etorrent/tree/master/rel) - stuff for making releases

The release stuff follow the general conventions laid bare by *rebar*
so I wont be covering it here. The file
[reltool.config](https://github.com/jlouis/etorrent/tree/master/rel/reltool.config)
is important though. It defines what to pack up in an embedded
etorrent Erlang VM and what applications to start up at boot.

# Building a development environment

This is documented in README.md, so follow the path from there. If it
doesn't work, get back to us so we can get the documentation updated.

# Code walk-through.

This is the meaty part. I hope it will help a hacker to easily see
what is happening in the application. And make it easier for him or
her to understand the application. If we can give the hacker a
bootstrap-start in understanding, we have succeeded.

There is a supervisor-structure documented by the date in the
[/documentation](https://github.com/jlouis/etorrent/tree/master/documentation). You
may wish to peruse it and study it while reading the rest of this document.

## Top level structure.

The two important program entry points are:

   * [etorrent_app.erl](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/src/etorrent_app.erl)
   * [etorrent_sup.erl](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/src/etorrent_sup.erl)

The `etorrent_app` defines what is needed to make etorrent an
application. When we make a release through the release system, we
arrange that this application will be started automatically. So that
is what makes etorrent start up. The important function is
`etorrent_app:start/2` which does some simple configuration and then
launches the main supervisor, `etorrent_sup`.

The main etorrent supervisor starts up *lots of stuff*. The things
started fall into three categories:

  * Global book-keepers. These processes keep track of global state
    and are not expected to die. They are usually fairly simple
    doing very few things by themselves. Most of them
    store state in ETS tables, and reading can usually bypass the
    governing process for speed.

  * Global processes. Any process in etorrent is either *global*,
    *torrent local* or *peer local* depending on whether it is used by
    all torrents, by a single torrent or by a single peer
    respectively. This split is what gives us fault tolerance. If a
    torrent dies, isolation gives us that only that particular torrent
    will; if a peer dies, it doesn't affect other peers.

  * Supervisors. There are several. The most important is the one
    maintaining a pool of torrents. Other maintain sub-parts of the
    protocol which are not relevant to the initial understanding.

An important supervisor maintains the Directory Watcher. This process,
the
[etorrent_dirwatcher](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/src/etorrent_dirwatcher.erl)
is a gen_server which is the starting entry point for the life cycle
of a torrent. It periodically watches the directory and when a torrent
is added, it will execute
[etorrent_ctl:start/1](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/src/etorrent_ctl.erl)
to actually start the torrent.

The
[etorrent_ctl](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/src/etorrent_ctl.erl)
gen_server is an interface to start and stop torrents for
real. Starting a torrent is very simple. We start up a torrent
supervisor and add it to the pool of currently alive torrents. Nothing
more happens at the top level -- the remaining work is by the torrent
supervisor, found in [etorrent_torrent_sup](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/src/etorrent_torrent_sup.erl).

### The etorrent module

The module [etorrent](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/src/etorrent.erl) is an interface to etorrent via the erl
shell. Ask it to give help by running `etorrent:help()`.

## Torrent supervisors

The torrent supervisor is
[etorrent_torrent_sup](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/src/etorrent_torrent_sup.erl).
This one will initially spawn supervisors to handle a pool of
filesystem processes and a pool of peers. And finally, it will spawn a
controller process, which will control the torrent in question.

Initially, the control process will wait in line until it is its turn
to perform a *check* of the torrent for correctness. To make the check
fast, there is a global process, the
[fast_resume](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/src/etorrent_fast_resume.erl)
process which persists the check data to disk every 5 minutes. If the
fast-resume data is consistent this is used for fast
checking. Otherwise, the control-process will check the torrent for
pieces missing and pieces which we have. It will then spawn a process
in the supervisor, by adding a child, the [tracker_communication](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/src/etorrent_tracker_communication.erl)
process.

Tracker communication will contact the tracker and get a list of
peers. It will report to the tracker that we exist, that we started
downloading the torrent, how many bytes we have
downloaded/uploaded -- and how many bytes there are left to download. The
tracker process lives throughout the life-cycle of a torrent. It
periodically contacts the tracker and it will also make a last contact
to the tracker when the torrent is *stopped*. This final contact is
ensured since the tracker-communicator process traps exits.

The peers are then sent to a *global* process, the
[peer_mgr](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/src/etorrent_peer_mgr.erl),
which manages peers. Usually the peers will be started by adding them
back into the peer pool of the right torrent right away. However, if
we have too many connections to peers they will enter a queue, waiting
in order. Also, peers will be filtered away, if we are already connected to
them. There is little reason to connect to the same peer multiple times.

**Incoming peer connections** To handle incoming connections, we have
a global supervisor maintaining a small pool of accepting
processes. When a peer connects to us, we perform part of the
handshake in the acceptor-process. We confer with several other parts
of the system. As soon as the remote peer transfers the InfoHash, we
look it up locally to see if this is a torrent we are currently
working on. If not, we kill the connection. If the torrent is alive,
we check to see if too many peers are connected, otherwise we allow
it, blindly (there is an opportunity for an optimization here).

## Peers

A peer is governed by a supervisor as well, the
[etorrent_peer_sup](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/src/etorrent_peer_sup.erl). It will control three gen_servers: One for
sending messages  to the remote peer and keeping a queue of outgoing
messages
([etorrent_peer_send](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/src/etorrent_peer_send.erl)). One
for receiving and decoding incoming messages ([etorrent_peer_recv](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/src/etorrent_peer_recv.erl)). And
finally one for controlling the communication and running the peer
wire protocol we use to communicate with peers ([etorrent_peer_control](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/src/etorrent_peer_control.erl)).

The supervisor is configured to die at the *instant* one of the other
processes die. And the peer pool supervisor parent assumes everything
are temporary. This means that an error in a peer will kill all peer
processes and it will remove the peer. There is a *monitor* set by the
`peer_mgr` on the peer, so it may try to connect in more peers when it
registers death of a peer. In turn, this behaviour ensures progress.

Peers are rather *autonomous* to the rest of the system. But they are
collaborating with several torrent-local and global processes. In the
following, we will try to explain what these collaborators do and how
they work.

## File system

The file system code, hanging on [etorrent_torrent_sup](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/src/etorrent_torrent_sup.erl)) as a
supervision tree maintains the storage of the file on-disk. Peers
communicate with these processes to read out pieces and store
pieces. The FS processes is split so there is a process per file. And
that file-process governs reading and writing. There is also a
directory-process which knows about how to write and read a piece by
its offsets and lengths into files. For multifile-torrents a single
piece read may span several files and this directory makes it possible
to know whom to ask.

## Chunk/Piece Management

There are two, currently global, processes called the
[etorrent_piece_mgr](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/src/etorrent_piece_mgr.erl)
and
([etorrent_chunk_mgr](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/src/etorrent_chunk_mgr.erl). The
first of these, the Piece Manager, keeps track of pieces for torrents
we are downloading. In particular it maps what pieces we have
downloaded and what pieces we are missing. It is used by peer
processes so they can tell remote peers what pieces we have.

The BitTorrent protocol does not exchange pieces. It exchanges
*slices* of pieces. These are in etorrent terminology called *chunks*
although other clients use *slices* or *sub-pieces* for the same
thing. To keep track of *chunks* we have the Chunk Manager. When a
piece is chosen for downloading, it is "chunked" -- split -- into
smaller 16 Kilobyte chunks. These are then requested from peers. Note
we prefer to get all chunks of a piece downloaded as fast as
possible -- so we may mark the piece as done and then exchange it with
other peers. Hence the chunk selecting algorithm prefers already
chunked up pieces.

Another important part of the chunk manager is to ensure exclusive
access to a chunk. There is little reason to download the same chunk
from multiple peers. We earmark chunks to peers. If the peer dies, a
monitor ensures we get the pieces back into consideration for other
peers. Finally, there is a special *endgame* mode which is triggered
when we are close to having the complete file downloaded. In this
mode, we ignore the exclusivity rule and spam requests to all
connected peers. The current rule is that when there are no more
pieces to chunk up and we can't get exclusive pieces, we "steal" from
other peers. A random shuffle of remaining pieces tries to eliminate
too many multiples.

**Note:** This part of the code is under rework at the moment. In
particular we seek to make the processes torrent-local rather than
global and maintain the piece maps and chunk maps differently. Talk to
Magnus Klaar for the details.

## Choking

A central point to the BitTorrent protocol is that you keep, perhaps,
200 connections to peers; yet you only communicate to a few of them,
some 10-20. This in turn avoids congestion problems in TCP/IP. The
process of choosing whom to communicate with is called
*choking/unchoking*. There is a glfobal server process, the
[etorrent_choker](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/src/etorrent_choker.erl),
responsible for selecting the peers to communicate with. It wakes up
every 10 seconds and then re-chokes peers.

The rules are quite intricate and it is advised to study them in
detail if you want to hack on this part. To make the decision several
parameters are taken into account:

   * The rate of the peer, either in send or receive direction.
   * Is the peer choking us?
   * Is the peer interested in pieces we have?
   * Are we interested in pieces the peer has?
   * Is the peer connected to a torrent we seed or leech?

Furthermore, we have a circular ring of peers used for *optimistic
un-choking*. The ring is moved forward a notch every 30 seconds and
ensures that *all* peers eventually get a chance at being unchoked. If
a peer is better than those we already download from, we will by this
mechanism eventually latch onto it.

## UDP tracking

BEP 15 adds the ability to contact a tracker by UDP packets rather
than use HTTP over TCP as one would normally do. The interface to the
UDP tracking system is the process
[etorrent_udp_tracker_mgr](https://github.com/jlouis/etorrent/tree/master/apps/etorrent/src/etorrent_choker.erl)

(** --- Editing to here --- **)

**Describe the remaining parts**

## DHT
...
## WebUI
...
## Event handling
...

# So you want to hack etorrent? Cool!

I am generally liberal, but there is one thing you should not do:

Patch Bombs.

A patch bomb is when a developer sits in his own corner for 4-5 months
and suddenly comes by with a patch of gargantuan size, say several
thousand lines of code changes. I won't accept such a patch - ever.

If you have a cool plan, I encourage you to mail me:
jesper.louis.andersen@gmail.com so we can set up a proper mailing list
and document our design discussions in the list archives. That way, we
may be able to break the problem into smaller pieces and we may get a
better solution by discussing it beforehand.

If you have a bug-fix or smaller patch it is ok to just come with it,
preferably on google code as a regular patch(1) or a git-patch. If you
know it is going to take you a considerable amount of time fixing the
problem, submit an issue first and then hack away. That way, others
may be able to chime in and comment on the problem.

*Remember to add yourself to the AUTHORS list.*

## "I just want to hack, what is there to do?"

Check the Issue tracker for enhancement requests and bugs. Ask me. I
might have something you would like to do. The TODO list are "Things
we certainly need to do!" and the issue tracker is used for "Things we
may do."  Note that people can vote up stuff on the issue tracker.

