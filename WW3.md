# Etorrent coding conventions

## Why?

Every programmer has their own view on what counts as reabable code
and they are all wrong. This document is my way of blessing the world
with a set of rules outlining the one true way.

# Prefix module names

Module names should always be prefixed with __etorrent___. If the module
can be considered to be a member of a logical group of modules the name should
also be prefixed with the name of the group. An example of such a grouping is
__etorrent_io___.

# Suffixing module names 

Module names should always contain a suffix if the behaviour or purpose
of the module falls into a general class of modules. The suffix should
be short and descriptive suffix.

Examples of such suffixes is ___sup__ and ___proto__.

# Not suffixing module names

If the module name does not fall into one of those general classes of modules
a suffix should not be invented because this makes module suffixes meaningless.

# Exports

## Grouped exports

Separate export directives should be used to group the type of functions that a
module exports If a module implements an OTP behaviour the callback functions should
always be grouped into one export directive. If a module exports functions for
working with entries in the gproc registry these should also be grouped into another
export directive.

## Verical exports

Functions in an export directive should always be separated by line breaks.
This makes it easier to scan through the list of functions while also making
it easier to spot what has been modified when viewing the changes in a commit.

    %% gen_server callbacks
    -export([init/1,
             handle_call/3,
             handle_cast/2,
             handle_info/2,
             terminate/2,
             code_change/3]).
    
    %% gproc registry entries
    -export([register_chunk_server/1,
             unregister_chunk_server/1,
             lookup_chunk_server/1]).

# Function specifications

All functions should be annotated with a type specification. This helps
communicate what values a function expects and returns. Maximizing the
chances of dialyzer finding embarassing bugs is always a good thing.
Function specifications should also be provided for internal functions.

# Defining records

Fields in record defenitions should be separated by line breaks. All fields
in a record defenitions should include a type specification. Default values
should be ommitted if the record is only constructed in a single function,
this is the common case with state records.

Ommitting the default values in the defenition and assigning each field a value
when creating a record saves readers from having to go back to the record
defenition to find out what the final result is.

# Matching on records

Fields and variable bindings should be separated by line breaks when a record
is used on the left side of the match operator. If only one or two fields are
matched a one-liner may be used.

        #state{
            info_hash=Infohash,
            remote_pieces=Pieceset} = State,

        #state{info_hash=InfoHash, remote_pieces=Pieceset} = State,

# Updating fields in a record

The same rules as matches on records apply.

        NewState = State#state{
            info_hash=NewInfohash,
            remote_pieces=NewPieceset},

        NewState = State#state{info_hash=NewInfohash, remote_pieces=NewPieceset},
    

# Records in function heads

Matches on records in function heads should be avoided if it's possible.
In the case of gen_server state the first expression should be to unpack
only the values in the state record that are necessary for the clause.

# When to use records

A record should be used for all composite data types. For small and short
lived groupings of values, such as returning two values from a function or
gen_server calls use of records is discouraged. Use of other data structures
where a record would have sufficied is discouraged.

# Variable names

## Camelcase

Variable names should not be more camelcased than is absolutely necessary.

__Infohash__ over __InfoHash__
__NewState__ over __Newstate__

Never use underscores in the middle of variable names. 

## Abbreviations

Variable names should not be abbreviated more than necessary. Ensuring
that lines don't get to long by using cryptic variable names is almost
always the wrong way to adhere to the line length limit.

__State__ over __S__
__Index__ over __Idx__
__Infohash__ over __Hash__

# Recursive functions

Use of recursive functions where a list comprehension or a foldr would
have sufficed is discouraged. Recursive functions with multiple parameters
that are updated on each call is also discouraged, try to find a more straight
forward way to implement the same function.

# Explicit return values

If the return value of a function is the result of complex expression or the
return value is tagged the returned value should be assigned to a variable
prior to the last expression. This makes it easier for readers to visually
determine where the function body ends.

    
    InitState = #state{
        torrent=TorrentID,
        ...
        files_max=MaxFiles},
    InitState.

    InitState = #state{
        torrent=TorrentID,
        ...
        files_max=MaxFiles},
    {ok, InitState}.

# Nested case expressions

Case expressions should not be nested if it isn't absolutely necessary.
Assigning the result of a case expression and later matching on that
is preferrable since it helps communicate the purpose of the case statement.

# Do not be clever

Saving lines of code by nesting expressions or being clever
with formatting will make anyone who is reading your code have to second
guess the final values of function parameters and results of expressions.

# Polymorphic functions

Functions that accepts values of multiple types are a pointless abstraction
if they are too generic. An example could be amodule encapsulating the persistent
state of etorrent.

        -type persistent_entity() :: {infohash(), bitfield()} | {dht_nodes, list()}.       
        -spec etorrent_persistent:save(persistent_entity()) -> ok.
        -spec etorrent_persistent:query(entity_match()) -> [persistent_entity()].

This type of interface scatters the operations that are performed on the persistent
state all over the codebase. A better alternative is to explicitly export these
operations from the etorrent_persistent module

        -spec etorrent_persistent:save_valid_pieces(infohash(), bitfield()) -> ok.
        -spec etorrent_persistent:get_valid_pieces(infohash()) -> {ok, bitfield()}.

        -spec etorrent_persistent:save_dht_nodes(list()) -> ok.
        -spec etorrent_persistent:get_dht_nodes() -> list().

# Domain specific wrappers

Although the datatypes provided by the standard library is sufficient to support
the implementation of any non trivial program it is often a good idea to wrap them
in a module that provides a more specific interface. If none of the datatypes
in the standard library provides the necessary functionality, consider using a
wrapper module to compose two or more of them.

# Module summaries

A summary of the purpose and implementation of a module should be included
if the module is anything non trivial. Not doing so is the same as wasting
the time spent designing the module.

# Inline EUnit tests

I prefer separating modules containg unit tests from the module implementing the
interface that is being tested because it emphasises that unit tests should
cover the public interface of a software component.

A reasonable tradeoff is to include the unit tests in the module implementing
the interface but restrict the tests to making fully qualified calls.

In these cases it's good to provide a short module name alias over hardcoding
the module name or using the ?MODULE macro because it makes the test code
look less contrived.

# False test coverage

Unit tests should contain as many assertions as possible without going overboard.
This is to avoid situations where a part of the code is covered by a test but
the effect that the code has on the result is never verified to be correct.

# Reasonable tests

It's a known fact that unit tests are more prone to be deprecated by design
changes than integration tests or system tests. The conclusion that should
be drawn from this isn't that unit tests are a waste of time to write.

A unit test that is quick and dirty is always better than one that would have
adhered to all of the rules if it was ever written.

# Line lengths

Lines should not exceed 80 characters. This limit is imposed because
it is difficult to read *wide* code, therefore it makes sense to make
exceptions to this rule if the alternative is more difficult to read.

# Separating functions and function clauses

 * Two blank lines should be used to separate function defenitions.
 * One blank line should be used to separate function clauses.

# Header files

The use of header files is discouraged because it burdens the reader with
having to keep multiple files in mind when reading a module.
