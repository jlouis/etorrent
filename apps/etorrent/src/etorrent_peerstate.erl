-module(etorrent_peerstate).
-export([new/1,
         new/3,
         choked/1,
         choked/2,
         interested/1,
         interested/2,
         interesting/2,
         interesting/3,
         seeder/1,
         seeder/2,
         seeding/1,
         seeding/2,
         pieces/1,
         requests/1,
         requests/2,
         needreqs/1]).

%% Piece set initialization functions.
-export([hasset/2,
         hasone/2,
         hasnone/1,
         hasall/1,
         pieces/2,
         haspieces/1]).


-type pieceset() :: etorrent_pieceset:pieceset().
-type pieceindex() :: etorrent_types:pieceindex().
-type rqueue() :: etorrent_rqueue:rqueue().
-record(peerstate, {
    pieces     = exit(required) :: integer() | pieceset(),
    choked     = exit(required) :: boolean(),
    interested = exit(required) :: boolean(),
    seeder     = exit(required) :: boolean(),
    requests   = exit(required) :: rqueue()}).
-opaque peerstate() :: #peerstate{}.
-export_type([peerstate/0]).

-spec new(integer()) -> peerstate().
new(NumPieces) ->
    new(NumPieces, 2, 250).

-spec new(integer(), integer(), integer()) -> peerstate().
new(Numpieces, QLow, QHigh) ->
    Requests = etorrent_rqueue:new(QLow, QHigh),
    State = #peerstate{
        pieces=Numpieces,
        choked=true,
        interested=false,
        seeder=false,
        requests=Requests},
    State.


-spec pieces(peerstate()) -> pieceset().
pieces(Peerstate) ->
    #peerstate{pieces=Pieces} = Peerstate,
    is_integer(Pieces) andalso erlang:error(badarg),
    Pieces.


-spec hasset(binary(), peerstate()) -> peerstate().
hasset(Bitfield, Peerstate) ->
    #peerstate{pieces=Pieces} = Peerstate,
    is_integer(Pieces) orelse erlang:error(badarg),
    Pieceset = etorrent_pieceset:from_binary(Bitfield, Pieces),
    Peerstate#peerstate{pieces=Pieceset}.


-spec hasone(pieceindex(), peerstate()) -> peerstate().
hasone(Piece, Peerstate) ->
    #peerstate{pieces=Pieces} = Peerstate,
    NewPieces = case is_integer(Pieces) of
        false -> etorrent_pieceset:insert(Piece, Pieces);
        true  -> etorrent_pieceset:from_list([Piece], Pieces)
    end,
    Peerstate#peerstate{pieces=NewPieces}.


-spec hasnone(peerstate()) -> peerstate().
hasnone(Peerstate) ->
    #peerstate{pieces=Pieces} = Peerstate,
    is_integer(Pieces) orelse erlang:error(badarg),
    NewPieces = etorrent_pieceset:empty(Pieces),
    Peerstate#peerstate{pieces=NewPieces}.


-spec hasall(peerstate()) -> peerstate().
hasall(Peerstate) ->
    #peerstate{pieces=Pieces} = Peerstate,
    is_integer(Pieces) orelse erlang:error(badarg),
    NewPieces = etorrent_pieceset:full(Pieces),
    Peerstate#peerstate{pieces=NewPieces, seeder=true}.


-spec pieces(pieceset(), peerstate()) -> peerstate().
pieces(Pieceset, Peerstate) ->
    #peerstate{pieces=Pieces} = Peerstate,
    is_integer(Pieces) orelse erlang:error(badarg),
    Peerstate#peerstate{pieces=Pieceset}.

%% TODO - this doesn't work. We would be better off
%% splitting the "peerstate" up into a few processes
%% base on a better criteria than the current one.
-spec haspieces(peerstate()) -> boolean().
haspieces(Peerstate) ->
    #peerstate{pieces=Pieces} = Peerstate,
    not is_integer(Pieces).


-spec choked(peerstate()) -> boolean().
choked(Peerstate) ->
    Peerstate#peerstate.choked.


-spec choked(boolean(), peerstate()) -> peerstate().
choked(Status, Peerstate) ->
    #peerstate{choked=Current} = Peerstate,
    Status /= Current orelse erlang:error(badarg),
    Peerstate#peerstate{choked=Status}.


-spec interested(peerstate()) -> boolean().
interested(Peerstate) ->
    Peerstate#peerstate.interested.


-spec interested(boolean(), peerstate()) -> peerstate().
interested(Status, Peerstate) ->
    #peerstate{interested=Current} = Peerstate,
    Status /= Current orelse erlang:error(badarg),
    Peerstate#peerstate{interested=Status}.

%% @doc Check if a piece is interesting
%% This function is intended to be called when a have-message is
%% received from a peer. If we are already interested or we are
%% a seeding the torrent this check is not necessary. We may also
%% receive a full piece set from a peer. Apply the same rules as
%% for a single piece but do a full check instead of testing for
%% membership in the local set.
%% @end
-spec interesting(pieceindex() | pieceset(), peerstate()) -> peerstate().
interesting(Pieces, Peerstate) ->
    #peerstate{interested=Interested, seeder=Seeder, pieces=Local} = Peerstate,
    not is_integer(Local) orelse erlang:error(badarg),
    case {Seeder, Interested} of
        {true, _} -> Peerstate;
        {_, true} -> Peerstate;
        _ ->
            Interesting = case is_integer(Pieces) of
                true ->
                    not etorrent_pieceset:is_member(Pieces, Local);
                false ->
                    Diff = etorrent_pieceset:difference(Pieces, Local),
                    not etorrent_pieceset:is_empty(Diff)
            end,
            case Interesting of
                false -> Peerstate;
                true  -> etorrent_peerstate:interested(true, Peerstate)
            end
    end.


%% @doc Check if a set of pieces is still interesting
%% This function is intended to be called when a have-message is sent
%% to a peer. If we are not interested or if the peer did not provide
%% the piece our interest remains unchanged. If there is no longer a
%% difference between the peer's piece set and our piece set, return
%% false.
%% @end
-spec interesting(pieceindex(), peerstate(), peerstate()) -> peerstate().
interesting(Piece, Remotestate, Localstate) ->
    #peerstate{pieces=Remote} = Remotestate,
    #peerstate{pieces=Local, interested=Intersted} = Localstate,
    case Intersted of
        false -> Localstate;
        true ->
            case etorrent_pieceset:is_member(Piece, Remote) of
                false -> Localstate;
                true ->
                    Diff = etorrent_pieceset:difference(Remote, Local),
                    case etorrent_pieceset:is_empty(Diff) of
                        false -> Localstate;
                        true -> etorrent_peerstate:interested(false, Localstate)
                    end
            end
    end.
    


-spec seeder(peerstate()) -> boolean().
seeder(Peerstate) ->
    #peerstate{seeder=Seeder} = Peerstate,
    Seeder.

-spec seeder(boolean(), peerstate()) -> peerstate().
seeder(Status, Peerstate) ->
    Status orelse erlang:error(badarg),
    Peerstate#peerstate{seeder=Status}.

-spec seeding(peerstate()) -> boolean().
seeding(Peerstate) ->
    Pieces = pieces(Peerstate),
    etorrent_pieceset:is_full(Pieces).

-spec seeding(peerstate(), peerstate()) -> peerstate().
seeding(Remotestate, Localstate) ->
    #peerstate{seeder=LSeeder} = Localstate,
    #peerstate{seeder=RSeeder, pieces=RPieces} = Remotestate,
    case {LSeeder, RSeeder} of
        {false, _} -> Remotestate;
        {_, true}  -> Remotestate;
        {true, false} ->
            RSeeding = etorrent_pieceset:is_full(RPieces),
            etorrent_peerstate:seeder(RSeeding, Remotestate)
    end.
        


-spec requests(peerstate()) -> rqueue().
requests(Peerstate) ->
    #peerstate{requests=Requests} = Peerstate,
    Requests.

-spec requests(rqueue(), peerstate()) -> peerstate().
requests(Requests, Peerstate) ->
    Peerstate#peerstate{requests=Requests}.

-spec needreqs(peerstate()) -> boolean().
needreqs(Peerstate) ->
    #peerstate{choked=Choked, interested=Interested, requests=Requests} = Peerstate,
    Interested andalso not Choked andalso etorrent_rqueue:is_low(Requests).


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(state, ?MODULE).
-define(pset, etorrent_pieceset).
-define(rqueue, etorrent_rqueue).

testsize() -> 8.

defaults_test_() ->
    State = ?state:new(testsize()),
    [?_assert(?state:choked(State)),
     ?_assertNot(?state:interested(State)),
     ?_assertNot(?state:seeder(State)),
     ?_assertEqual(0, ?rqueue:size(?state:requests(State))),
     ?_assertNot(?state:needreqs(State)),
     ?_assertError(badarg, ?state:pieces(State)),
     ?_assertError(badarg, ?state:interesting(0, State))].

initset_test_() ->
    State = ?state:new(testsize()),
    P0 = ?state:pieces(?state:hasone(0, State)),
    P1 = ?state:pieces(?state:hasset(<<1:1, 0:7>>, State)),
    P2 = ?state:pieces(?state:hasall(State)),
    P3 = ?state:pieces(?state:hasnone(State)),
    [?_assertEqual(?pset:from_list([0], testsize()), P0),
     ?_assertEqual(?pset:from_list([0], testsize()), P1),
     ?_assertEqual(?pset:from_list([0,1,2,3,4,5,6,7], testsize()), P2),
     ?_assertEqual(?pset:from_list([], testsize()), P3)].

immutable_set_test_() ->
    S0 = ?state:new(testsize()),
    S1 = ?state:hasnone(S0),
    [?_assertError(badarg, ?state:hasset(<<1:1, 0:7>>, S1)),
     ?_assertError(badarg, ?state:hasall(S1)),
     ?_assertError(badarg, ?state:hasnone(S1)),
     ?_assertEqual(?state:hasone(0, S0), ?state:hasone(0, S1))].

seeder_revert_test_() ->
    S0 = ?state:new(testsize()),
    S1 = ?state:seeder(true, S0),
    [?_assert(?state:seeder(S1)),
     ?_assertError(badarg, ?state:seeder(false, S1))].

consistent_choked_test_() ->
    S0 = ?state:new(testsize()),
    S1 = ?state:choked(false, S0),
    [?_assertError(badarg, ?state:choked(true, S0)),
     ?_assertError(badarg, ?state:choked(false, S1)),
     ?_assertNot(?state:choked(S1))].

consistent_interested_test_() ->
    S0 = ?state:new(testsize()),
    S1 = ?state:interested(true, S0),
    [?_assertError(badarg, ?state:interested(false, S0)),
     ?_assertError(badarg, ?state:interested(true, S1)),
     ?_assert(?state:interested(S1))].

interesting_received_test_() ->
    S0 = ?state:new(testsize()),
    S1 = ?state:hasone(7, S0),
    S2 = ?state:interested(true, S1),
    [?_assertEqual(S1, ?state:interesting(7, S1)),
     ?_assert(?state:interested(?state:interesting(6, S1))),
     ?_assertEqual(S2, ?state:interesting(7, S2)),
     ?_assertEqual(S2, ?state:interesting(6, S2))].

interesting_sent_test_() ->
    L0 = ?state:interested(true, ?state:hasnone(?state:new(testsize()))),
    L1 = ?state:hasone(0, L0),
    L2 = ?state:hasone(1, L1),
    L3 = ?state:interested(false, L1),

    R0 = ?state:hasnone(?state:new(testsize())),
    R1 = ?state:hasone(0, R0),
    R2 = ?state:hasone(1, R1),

    [?_assertEqual(L1, ?state:interesting(0, R0, L1)),
     ?_assertNot(?state:interested(?state:interesting(0, R1, L1))),
     ?_assertEqual(L1, ?state:interesting(0, R2, L1)),
     ?_assertNot(?state:interested(?state:interesting(0, R2, L2))),
     ?_assertEqual(L3, ?state:interesting(0, R1, L3))].

seeding_test_() ->
    S0 = ?state:new(testsize()),
    [?_assert(?state:seeding(?state:hasall(S0))),
     ?_assertNot(?state:seeding(?state:hasnone(S0))),
     ?_assertNot(?state:seeding(?state:hasone(0, S0)))].

needreq_test_() ->
    S0 = ?state:hasnone(?state:new(testsize())),
    S1 = ?state:interested(true, S0),
    S2 = ?state:choked(false, S0),
    S3 = ?state:interested(true, ?state:choked(false, S0)),
    [?_assertNot(?state:needreqs(S0)),
     ?_assertNot(?state:needreqs(S1)),
     ?_assertNot(?state:needreqs(S2)),
     ?_assert(?state:needreqs(S3))].

request_update_test() ->
    S0 = ?state:hasnone(?state:new(testsize())),
    Reqs = ?state:requests(S0),
    NewReqs = ?rqueue:push(0, 0, 1, Reqs),
    S1 = ?state:requests(NewReqs, S0),
    ?assertEqual(NewReqs, ?state:requests(S1)).

-endif.
