# Handling both BEP-12 and BEP-15 simultaneously

## Abstract

The Bittorrent Enhancement Process (BEP) contain two proposals, BEP-12
and BEP-15. These two proposals are used in conjunction with each
other. This document describes how to handle them simultaneously,
based on what different clients do.

## Rationale

In the bittorrent system, it is beneficial to handle multiple trackers
at once. This proposal is BEP-12. Another beneficial proposal is to
handle tracker requests as UDP traffic (BEP-15), rather than relying
on TCP-traffic. The former provides redundancy, while the latter
provides efficient bandwidth utilization. BEP-15 does not, however,
describe how it is supposed that the client recognizes a tracker as
being UDP capable.

This proposal aims to remedy this shortcoming. It describes how some
clients *currently* handle the situation by a clever interplay between
BEP-12 and BEP-15. The goal is not to provide nor enforce a new
solution -- rather we opt for describing the de-facto method of
getting BEP-12 and 15 to interplay.

## Approach

BEP-12 contains the concept of multiple announcement URLs. These are
arranged in tiers of announcement URLs. We extend
the usual http://domain.com/foo/announce announce url schema with a new one:

   udp://domain.com

This schema designates an UDP capable tracker running at
domain.com. Note the deliberate omission of the path-component from
the URL. There is none for the UDP method. Trackers supplying an
udp:// schema MUST answer on UDP. A torrent file MAY choose to supply both
the http:// and udp:// schemas at the same time for trackers.

The udp:// schema MAY be used in any tier in a BEP-12 multi-tracker
designation anywhere in the lists of individual tiers.

### Equivalence

An http:// and udp:// schema are considered to be equivalent, provided
they have the same domain name. Otherwise they are considered to be
different.

## Client handling

A client which do not support BEP-15 SHOULD ignore *any* schemas it
doesn't know about, the udp:// schema included.

Clients contact udp:// schema trackers as described in BEP-15. A
failure to answer is regarded as if the tracker in the tier is
unreachable and the usual BEP-12 rules apply for finding the next
candidate tracker.

It is paramount that a client still provides adequate shuffling of
trackers as per BEP-12. The simple idea of letting udp:// schemas
"bubble" to the front of the list in each tier MUST be avoided. It
does not distribute the announce URLs evenly as it gives too much
preference to UDP capable trackers.

Rather, the client can use the following method:

### Preferral of UDP trackers

Given tiers

      T1, T2, ..., Tk

First shuffle each tier T1, T2, ..., Tk randomly as per the BEP-12
specification.

Then, treat this tier-list as a flat list of announce URLs. That is,
concatenate T1, T2, ..., Tk to form a single list. Ff udp:// and
http:// announce URLs are *equivalent* as per the above definition of
equivalence, swap them to make the udp:// schema come first,
disregarding tiers. Note that this allows the udp:// schema url to
move to an earlier tier.

After this swapping has occurred, treat everything as BEP-12. Note
that this will make a client prefer udp:// based trackers over http://
based trackers, even in the same tier. Yet, it still gives each tracker
the same probability distribution as the unshuffled list. We assume
that a tracker with both UDP and HTTP capability prefers to be
contacted on UDP.

The rationale for letting udp:// schemas move between tiers is that
many torrents are created with a single tracker announceURL in each
tier. Thus simply shuffling in each tier has no effect on such a
torrent file.

### Ordering example

Assume we have the following two tiers:

    {[http://one.com, udp://one.com, http://two.com],
     [http://three.com, udp://four.com, udp://two.com]}

As per BEP-12, random shuffling of these lists are carried
out. Here is one such random shuffling:

    {[http://one.com, http://two.com, udp://one.com],
     [http://four.com, udp://two.com, http://three.com]}

The UDP preference rule now swaps the "one.com" and "two.com" domains
to obtain the list:

    {[udp://one.com, udp://two.com, http://one.com],
     [http://four.com, http://two.com, http://three.com]}

At this point, we follow the rules from BEP-12, included moving the
succesful responses to the front of the list.

## Acknowledgements

We acknowledge Arvid Nordberg, and his libtorrent-rasterbar C++ code,
for the udp:// preference method. We also acknowledge Arvid for
helpful discussions of the method and critique of this BEP.

## References

   * BEP-12

   * BEP-15

## Copyright

  This document has been placed in the public domain.
