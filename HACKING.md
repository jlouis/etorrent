# Introduction

This document describes an architectural overview of the Etorrent
application. It is meant for hackers to be used for doing changes on
the application and bootstrap them to be able to do changes faster.

The document is currently dated:

    2010-12-22

And information herein might need a review if we are much after this
date because the code is in constant motion. This is a warning.

# General layout of the source code

This is the hierarchy:

    /apps/ - Container for the etorrent application
    /apps/etorrent/ - The etorrent application
    /apps/etorrent/doc/ - edoc-generated output for the etorrent app.
    /apps/etorrent/ebin/ - Where .beam files are compiled to
    /apps/etorrent/include/ - include (.hrl) files
    /apps/etorrent/priv/ - private data for the app.
    /apps/etorrent/src/ - main source code

The above should not pose any trouble with a seasoned or beginning
erlang hacker.

    /apps/etorrent/priv/webui/htdocs/

This directory contains the data used by the Web UI system. It is
basically dumping ground for Javascript code and anything static we
want to present to a user of the applications web interface.

    /deps/ - dependencies are downloaded to here
    /dev/ - when you generate development embedded VMs they go here
    /documentation/ - haphazard general documentation about etorrent
    /tools/ - small tools for manipulating and developing the source
    /rel/ - stuff for making releases

The release stuff follow the general conventions laid bare by *rebar*
so I wont be covering it here.

# Building a development environment

This is documented in README.md, so follow the path from there.

# Code walkthrough:

This is the meaty part. I hope it will help a hacker to easily see
what is happening in the application.

## Top level structure.


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

