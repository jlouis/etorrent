-module(etorrent_peerstate).
-export([new/1,
         choked/1,
         choked/2,
         interested/1,
         interested/2,
         interesting/2,
         interesting/3,
         seeder/1,
         seeder/2,
         pieces/1,
         requests/1,
         requests/2,
         needreqs/1]).

%% Piece set initialization functions.
-export([hasset/2,
         hasone/2,
         hasnone/1,
         hasall/1]).


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
new(Numpieces) ->
    Requests = etorrent_rqueue:new(),
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


-spec interesting(pieceindex(), peerstate()) -> unchanged | true.
interesting(Piece, Peerstate) ->
    #peerstate{interested=Status} = Peerstate,
    Pieces = pieces(Peerstate),
    NewStatus = case Status of
        %% If we are already interested this won't change that
        true  -> true;
        false -> etorrent_pieceset:is_member(Piece, Pieces)
    end,
    if  NewStatus == Status -> unchanged;
        true -> NewStatus
    end.


-spec interesting(pieceindex(), peerstate(), peerstate()) -> unchanged | boolean().
interesting(Piece, RemoteState, LocalState) ->
    Status = etorrent_peerstate:interested(LocalState),
    NewStatus = case Status of
        false -> false;
        true  ->
            Remote = etorrent_peerstate:pieces(RemoteState),
            case etorrent_pieceset:is_member(Piece, Remote) of
                false -> false;
                true  ->
                    Local = etorrent_peerstate:pieces(LocalState),
                    Difference = etorrent_pieceset:difference(Local, Remote),
                    not etorrent_pieceset:is_empty(Difference)
            end
    end,
    if  NewStatus == Status -> unchanged;
        true -> NewStatus
    end.
    


-spec seeder(peerstate()) -> boolean().
seeder(Peerstate) ->
    #peerstate{pieces=Pieceset, seeder=Seeder} = Peerstate,
    Seeder orelse etorrent_pieceset:is_full(Pieceset).

-spec seeder(boolean(), peerstate()) -> peerstate().
seeder(Status, Peerstate) ->
    #peerstate{seeder=Current} = Peerstate,
    Current == Status orelse erlang:error(badarg),
    not Status orelse erlang:error(badarg),
    Peerstate#peerstate{seeder=Status}.

-spec requests(peerstate()) -> rqueue().
requests(Peerstate) ->
    #peerstate{requests=Requests} = Peerstate,
    Requests.

-spec requests(rqueue(), peerstate()) -> peerstate().
requests(Requests, Peerstate) ->
    Peerstate#peerstate{requests=Requests}.

-spec needreqs(peerstate()) -> boolean().
needreqs(Peerstate) ->
    #peerstate{choked=Choked, requests=Requests} = Peerstate,
    not Choked andalso etorrent_rqueue:is_low(Requests).


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(state, ?MODULE).
-define(pset, etorrent_pieceset).

testsize() -> 8.

defaults_test_() ->
    State = ?state:new(testsize()),
    [?_assert(?state:choked(State)),
     ?_assertNot(?state:interested(State)),
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

-endif.

