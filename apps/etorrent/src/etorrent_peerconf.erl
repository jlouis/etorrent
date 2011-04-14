-module(etorrent_peerconf).
-export([new/0,
         peerid/1,
         peerid/2,
         extended/1,
         extended/2,
         fast/1,
         fast/2]).

-record(peerconf, {
    peerid = exit(required) :: none | <<_:160>>,
    extended = exit(required) :: boolean(),
    fast = exit(required) :: boolean()}).

-opaque peerconf() :: #peerconf{}.
-export_type([peerconf/0]).

-spec new() -> peerconf().
new() ->
    new(none).

-spec new(<<_:160>>) -> peerconf().
new(PeerID) ->
    Conf = #peerconf{
        peerid=PeerID,
        extended=true,
        fast=false},
    Conf.

-spec peerid(peerconf()) -> <<_:160>>.
peerid(Peerconf) ->
    #peerconf{peerid=PeerID} = Peerconf,
    PeerID /= none orelse erlang:error(badarg),
    PeerID.

-spec peerid(<<_:160>> | none, peerconf()) -> peerconf().
peerid(PeerID, Peerconf) ->
    #peerconf{peerid=Prev} = Peerconf,
    Prev == none orelse erlang:error(badarg),
    Peerconf#peerconf{peerid=PeerID}.

-spec extended(peerconf()) -> boolean().
extended(Peerconf) ->
    Peerconf#peerconf.extended.

-spec extended(boolean(), peerconf()) -> peerconf().
extended(Enabled, Peerconf) ->
    Peerconf#peerconf{extended=Enabled}.

-spec fast(peerconf()) -> boolean().
fast(Peerconf) ->
    Peerconf#peerconf.fast.

-spec fast(boolean(), peerconf()) -> peerconf().
fast(Enabled, Peerconf) ->
    Peerconf#peerconf{fast=Enabled}.
