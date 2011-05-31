-module(etorrent_peerconf).
-export([new/0,
         localid/1,
         localid/2,
         remoteid/1,
         remoteid/2,
         extended/1,
         extended/2,
         fast/1,
         fast/2]).

-record(peerconf, {
    localid  = exit(required) :: none | <<_:160>>,
    remoteid = exit(required) :: none | <<_:160>>,
    extended = exit(required) :: boolean(),
    fast = exit(required) :: boolean()}).

-opaque peerconf() :: #peerconf{}.
-export_type([peerconf/0]).

-spec new() -> peerconf().
new() ->
    Conf = #peerconf{
        localid=none,
        remoteid=none,
        extended=true,
        fast=false},
    Conf.


-spec localid(peerconf()) -> <<_:160>>.
localid(Peerconf) ->
    #peerconf{localid=LocalID} = Peerconf,
    LocalID /= none orelse erlang:error(badarg),
    LocalID.


-spec localid(<<_:160>>, peerconf()) -> peerconf().
localid(<<NewLocalID:160/bitstring>>, Peerconf) ->
    #peerconf{localid=LocalID} = Peerconf,
    LocalID == none orelse erlang:error(badarg),
    Peerconf#peerconf{localid=NewLocalID}.


-spec remoteid(peerconf()) -> <<_:160>>.
remoteid(Peerconf) ->
    #peerconf{remoteid=RemoteID} = Peerconf,
    RemoteID /= none orelse erlang:error(badarg),
    RemoteID.


-spec remoteid(<<_:160>>, peerconf()) -> peerconf().
remoteid(<<NewRemoteID:160/bitstring>>, Peerconf) ->
    #peerconf{localid=RemoteID} = Peerconf,
    RemoteID == none orelse erlang:error(badarg),
    Peerconf#peerconf{remoteid=NewRemoteID}.


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
