# Handling both BEP-12 and BEP-15 simultaneously

## Abstract

The Bittorrent Enhancement Process (BEP) contain two proposals, BEP-12
and BEP-15. These two proposals are used in conjunction with each
other. This document describes how to handle them simultaneously,
based on what different clients do.

## Rationale

In the bittorrent system, it is beneficial to be able to handle
multiple trackers at once. This proposal is BEP-12. Another beneficial
proposal is to handle tracker requests as UDP traffic (BEP-15) rather
than relying on TCP-traffic. The former provides redundancy, while the
latter provides efficient bandwidth utilization. BEP-15 does not,
however, describe how it is to be invoked by the client.

This BEP proposal is written to document what clients are *currently
doing* as opposed to what they ought to be doing. The goal is not to
enforce a new solution, but rather to describe an existing de-facto
method of getting BEP-12 and 15 to interplay with each other.

## Approach

BEP-12 contains the concept of multiple announcement URLs. We extend
the usual http:// announce url scheme with a new one:

   udp://...

many words can be traded on this choice, but as per the rationale, we
adopt a stance to document existing setups. The scheme signifies we
use UDP-tracking as per BEP-15. A tracker MAY choose to use this to
explicitly tell the client it supports UDP-tracking as per BEP-15. A
client which do not support BEP-15 SHOULD ignore *any* schemas it
doesn't know, the udp:// schema included.

A tracker MAY choose to supply an announce URL as the http:// scheme
and as the udp:// scheme at the same time. The client SHOULD prefer the
udp:// scheme if at all possible. The trackers are considered to be
equivalent if they point to the same domain name, ignoring the path
component (which does not make sense in the udp:// scheme).

### Preferral of UDP trackers

The rule for preferring UDP trackers is this: If an UDP tracker is
found, search the current tier and earlier tiers (see BEP-12 for the
definition of a tier). If the corresponding HTTP tracker announce URL
is found (it is equivalent), swap the UDP tracker for the HTTP to make
the UDP tracker come first.

#### Ordering example

Among a BEP-12 tier, the client SHOULD prefer udp:// schema URIs in a
tier. Thus, if the tiers are

    {[http://one.com, udp://one.com, http://two.com],
     [http://three.com, udp://four.com, udp://two.com]}

we SHOULD process them in the following order, from top to bottom:

   udp://one.com, udp://two.com http://one.com udp://four.com
   {http://three.com, http://two.com} -- any of these followed by the
   other per shuffle rules of BEP-12

Note that if the udp:// tracker responds, it will be moved to the
front of the tier and thus be used in subsequent requests.

## Acknowledgements

We acknowledge Arvid Nordberg, and his libtorrent-rasterbar C++ code,
for the above method. The description is loosely based upon what the
libtorrent code is doing.

## References

BEP-12
BEP-15

## Copyright

  This document has been placed in the public domain.
