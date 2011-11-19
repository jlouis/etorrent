%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Compute the set of ALLOWED_FAST for the FAST-EXTENSION.
%% <p><b>This module is currently not in use</b></p>
%% <p>This module has a single function, to compute the allowed fast
%% set of a peer basic on the IP address of the peer in question.</p>
-module(etorrent_allowed_fast).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("log.hrl").

%% API
-export([allowed_fast/4]).

%%====================================================================

%% @doc Compute the allowed fast set for a peer
%% <p>We are given Sz - the number of pieces, an IP-tuple, K - the number of
%% pieces to compute and the InfoHash of the torrent. We compute the
%% allowed fast set - a small set of pieces a peer has exclusive
%% access to always when it wants to request.</p>
%% @end
-type ip() :: {integer(), integer(), integer(), integer()}.
-spec allowed_fast(integer(), ip() | binary(), integer(), binary()) ->
                          {value, set()}.
allowed_fast(Sz, {B1, B2, B3, B4}, K, InfoHash) ->
    B = <<B1:8/integer, B2:8/integer, B3:8/integer, B4:8/integer>>,
    allowed_fast(Sz, B, K, InfoHash);
allowed_fast(Sz, <<B1:8/integer, B2:8/integer, B3:8/integer, _B4:8/integer>>,
                  K, InfoHash) ->
    20 = byte_size(InfoHash),
    %% Rip out the last byte. It means that you need more than a /24
    %%  in order to fool us.
    IpX = <<B1:8/integer, B2:8/integer, B3:8/integer, 0:8/integer>>,
    %% Seed with the Infohash
    X = <<IpX:4/binary, InfoHash/binary>>,
    %% Begin running rounds on an empty set
    rnd(K, X, Sz, sets:new()).

%%====================================================================

rnd(0, _X, _Sz, Set) -> {value, Set};
rnd(K, X, Sz, Set) ->
    %% Start a new round. Each round hashes the previous round to gen.
    %%  a pseudo-random sequence
    NX = crypto:sha(X),
    %% Cut into the current NX sequence.
    cut(K, 0, NX, Sz, Set).

cut(0, _I, _X, _Sz, Set) ->
    %% nNo more pieces wanted
    {value, Set};
cut(K, 5, X, Sz, Set) ->
    %% We exhausted the X binary. Start a new round.
    rnd(K, X, Sz, Set);
cut(K, I, X, Sz, Set) ->
    %% Pick out an Index
    J = I * 4,
    <<_Skip:J/binary, Y:32/integer, _Rest/binary>> = X,
    Index = Y rem Sz,
    %% Stuff it into the set if it isn't there already.
    case sets:is_element(Index, Set) of
        true ->
            cut(K, I+1, X, Sz, Set);
        false ->
            cut(K-1, I+1, X, Sz, sets:add_element(Index, Set))
    end.

%%====================================================================
%% Tests
%%====================================================================
-ifdef(EUNIT).

allowed_fast_1_test() ->
    N = 16#AA,
    InfoHash = list_to_binary(lists:duplicate(20, N)),
    {value, PieceSet} = allowed_fast(1313, {80,4,4,200}, 7, InfoHash),
    Pieces = lists:sort(sets:to_list(PieceSet)),
    ?assertEqual([287, 376, 431, 808, 1059, 1188, 1217], Pieces).

allowed_fast_2_test() ->
    N = 16#AA,
    InfoHash = list_to_binary(lists:duplicate(20, N)),
    {value, PieceSet} = allowed_fast(1313, {80,4,4,200}, 9, InfoHash),
    Pieces = lists:sort(sets:to_list(PieceSet)),
    ?assertEqual([287, 353, 376, 431, 508, 808, 1059, 1188, 1217], Pieces).

-endif.
