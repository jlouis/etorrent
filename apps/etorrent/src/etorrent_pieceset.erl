-module(etorrent_pieceset).
-include("types.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-undef(LET).
-include_lib("eqc/include/eqc.hrl").
-endif.

-export([new/1,
         from_binary/2,
         to_binary/1,
         from_list/2,
         to_list/1,
         is_member/2,
         is_empty/1,
         insert/2,
         delete/2,
         intersection/2,
         difference/2,
         size/1,
         min/1]).

-record(pieceset, {
    size :: non_neg_integer(),
    elements :: binary()}).

-opaque pieceset() :: #pieceset{}.
-export_type([pieceset/0]).

%% @doc
%% Create an empty set of piece indexes. The set of pieces
%% is limited to contain pieces indexes from 0 to Size-1.
%% @end
-spec new(non_neg_integer()) -> pieceset().
new(Size) ->
    Elements = <<0:Size>>,
    #pieceset{size=Size, elements=Elements}.

%% @doc
%% Create a piece set based on a bitfield. The bitfield is
%% expected to contain at most Size pieces. The piece set
%% returned by this function is limited to contain at most
%% Size pieces, as a set returned from new/1 is.
%% The bitfield is expected to not be padded with more than 7 bits.
%% @end
-spec from_binary(binary(), non_neg_integer()) -> pieceset().
from_binary(Bin, Size) when is_binary(Bin) ->
    PadLen = paddinglen(Size),
    <<Elements:Size/bitstring, PadValue:PadLen>> = Bin,
    %% All bits used for padding must be set to 0
    case PadValue of
        0 -> #pieceset{size=Size, elements=Elements};
        _ -> error(badarg)
    end.

%% @doc
%% Convert a piece set to a bitfield, the bitfield will
%% be padded with at most 7 bits set to zero.
%% @end
-spec to_binary(pieceset()) -> binary().
to_binary(Pieceset) ->
    #pieceset{size=Size, elements=Elements} = Pieceset,
    PadLen = paddinglen(Size),
    <<Elements/bitstring, 0:PadLen>>.

%% @doc
%% Convert an ordered list of piece indexes to a piece set.
%% @end
-spec from_list(list(non_neg_integer()), non_neg_integer()) -> pieceset().
from_list(List, Size) ->
    Pieceset = new(Size),
    from_list_(List, Pieceset).

from_list_([], Pieceset) ->
    Pieceset;
from_list_([H|T], Pieceset) ->
    from_list_(T, insert(H, Pieceset)).


%% @doc
%% Convert a piece set to an ordered list of the piece indexes
%% that are members of this set.
%% @end
-spec to_list(pieceset()) -> list(non_neg_integer()).
to_list(Pieceset) ->
    #pieceset{elements=Elements} = Pieceset,
    to_list(Elements, 0).

to_list(<<1:1, Rest/bitstring>>, Index) ->
    [Index|to_list(Rest, Index + 1)];
to_list(<<0:1, Rest/bitstring>>, Index) ->
    to_list(Rest, Index + 1);
to_list(<<>>, _) ->
    [].

%% @doc
%% Returns true if the piece is a member of the piece set,
%% false if not. If the piece index is negative or is larger
%% than the size of this piece set, the function exits with badarg.
%% @end
-spec is_member(non_neg_integer(), pieceset()) -> boolean().
is_member(PieceIndex, _) when PieceIndex < 0 ->
    error(badarg);
is_member(PieceIndex, Pieceset) ->
    #pieceset{size=Size, elements=Elements} = Pieceset,
    case PieceIndex < Size of
        false ->
            error(badarg);
        true ->
            <<_:PieceIndex/bitstring, Status:1, _/bitstring>> = Elements,
            Status > 0
    end.

%% @doc
%% Returns true if there are any members in the piece set.
%% @end
-spec is_empty(pieceset()) -> boolean().
is_empty(Pieceset) ->
    #pieceset{size=Size, elements=Elements} = Pieceset,
    <<Memberbits:Size>> = Elements,
    Memberbits == 0.

%% @doc
%% Insert a piece into the piece index. If the piece index is
%% negative or larger than the size of this piece set, this
%% function exists with the reason badarg.
%% @end
-spec insert(non_neg_integer(), pieceset()) -> pieceset().
insert(PieceIndex, _) when PieceIndex < 0 ->
    error(badarg);
insert(PieceIndex, Pieceset) ->
    #pieceset{size=Size, elements=Elements} = Pieceset,
    case PieceIndex < Size of
        false ->
            error(badarg);
        true ->
            <<Low:PieceIndex/bitstring, _:1, High/bitstring>> = Elements,
            Updated = <<Low/bitstring, 1:1, High/bitstring>>,
            Pieceset#pieceset{elements=Updated}
    end.

%% @doc
%% Delete a piece from a pice set. If the index is negative
%% or larger than the size of the piece set, this function
%% exits with reason badarg.
%% @end
-spec delete(non_neg_integer(), pieceset()) -> pieceset().
delete(PieceIndex, _) when PieceIndex < 0 ->
    error(badarg);
delete(PieceIndex, Pieceset) ->
    #pieceset{size=Size, elements=Elements} = Pieceset,
    case PieceIndex < Size of
        false ->
            error(badarg);
        true ->
            <<Low:PieceIndex/bitstring, _:1, High/bitstring>> = Elements,
            Updated = <<Low/bitstring, 0:1, High/bitstring>>,
            Pieceset#pieceset{elements=Updated}
    end.

%% @doc
%% Return a piece set where each member is a member of both sets.
%% If both sets are not of the same size this function exits with badarg.
%% @end
-spec intersection(pieceset(), pieceset()) -> pieceset().
intersection(Set0, Set1) ->
    #pieceset{size=Size0, elements=Elements0} = Set0,
    #pieceset{size=Size1, elements=Elements1} = Set1,
    case Size0 == Size1 of
        false ->
            error(badarg);
        true ->
            <<E0:Size0>> = Elements0,
            <<E1:Size1>> = Elements1,
            Shared = E0 band E1,
            Intersection = <<Shared:Size0>>,
            #pieceset{size=Size0, elements=Intersection}
    end.

%% @doc
%% Return a piece set where each member is a member of the first
%% but not a member of the second set.
%% If both sets are not of the same size this function exits with badarg.
%% @end
difference(Set0, Set1) ->
    #pieceset{size=Size0, elements=Elements0} = Set0,
    #pieceset{size=Size1, elements=Elements1} = Set1,
    case Size0 == Size1 of
        false ->
            error(badarg);
        true ->
            <<E0:Size0>> = Elements0,
            <<E1:Size1>> = Elements1,
            Unique = (E0 bxor E1) band E0,
            Difference = <<Unique:Size0>>,
            #pieceset{size=Size0, elements=Difference}
    end.


%% @doc
%% Return the number of pieces that are members of the set.
%% @end
-spec size(pieceset()) -> non_neg_integer().
size(Pieceset) ->
    #pieceset{elements=Elements} = Pieceset,
    size(Elements, 0).

size(<<1:1, Rest/bitstring>>, Acc) ->
    size(Rest, Acc + 1);
size(<<0:1, Rest/bitstring>>, Acc) ->
    size(Rest, Acc);
size(<<>>, Acc) ->
    Acc.

%% @doc
%% Return the lowest piece index that is a member of this set.
%% If the piece set is empty, exit with reason badarg
%% @end
-spec min(pieceset()) -> non_neg_integer().
min(Pieceset) ->
    #pieceset{elements=Elements} = Pieceset,
    min_(Elements, 0).

min_(Elements, Offset) ->
    Half = bit_size(Elements) div 2,
    case Elements of
        <<>> ->
            error(badarg);
        <<0:1>> ->
            error(badarg);
        <<1:1>> ->
            Offset;
        <<0:Half, Rest/bitstring>> ->
            min_(Rest, Offset + Half);
        <<Rest:Half/bitstring, _/bitstring>> ->
            min_(Rest, Offset)
    end.

paddinglen(Size) ->
    Length = 8 - (Size rem 8),
    case Length of
        8 -> 0;
        _ -> Length
    end.


-ifdef(TEST).
-define(set, ?MODULE).

%% The highest bit in the first byte corresponds to piece 0.
high_bit_test() ->
    Set = ?set:from_binary(<<1:1, 0:7>>, 8),
    ?assert(?set:is_member(0, Set)).

%% And the bit after that corresponds to piece 1.
bit_order_test() ->
    Set = ?set:from_binary(<<1:1, 1:1, 0:6>>, 8),
    ?assert(?set:is_member(0, Set)),
    ?assert(?set:is_member(1, Set)).

%% The lowest bit in the first byte corresponds to piece 7,
%% and the highest bit in the second byte corresponds to piece 8.
byte_boundry_test() ->
    Set = ?set:from_binary(<<0:7, 1:1, 1:1, 0:7>>, 16),
    ?assert(?set:is_member(7, Set)),
    ?assert(?set:is_member(8, Set)).

%% The remaining bits should be padded with zero and ignored
padding_test() ->
    Set = ?set:from_binary(<<0:8, 0:6, 1:1, 0:1>>, 15),
    ?assert(?set:is_member(14, Set)),
    ?assertError(badarg, ?set:is_member(15, Set)).

%% If the padding is invalid, the conversion from
%% bitfield to pieceset should crash.
invalid_padding_test() ->
    ?assertError(badarg, ?set:from_binary(<<0:7, 1:1>>, 7)).

%% Piece indexes can never be less than zero
negative_index_test() ->
    ?assertError(badarg, ?set:is_member(-1, undefined)).

%% Piece indexes that fall outside of the index range should fail
too_high_member_test() ->
    Set = ?set:new(8),
    ?assertError(badarg, ?set:is_member(8, Set)).

%% An empty piece set should contain 0 pieces
empty_size_test() ->
    ?assertEqual(0, ?set:size(?set:new(8))),
    ?assertEqual(0, ?set:size(?set:new(14))).

full_size_test() ->
    Set0 = ?set:from_binary(<<255:8>>, 8),
    ?assertEqual(8, ?set:size(Set0)),
    Set1 = ?set:from_binary(<<255:8, 1:1, 0:7>>, 9),
    ?assertEqual(9, ?set:size(Set1)).

%% An empty set should be converted to an empty list
empty_list_test() ->
    Set = ?set:new(8),
    ?assertEqual([], ?set:to_list(Set)).

%% Expect the list to be ordered from smallest to largest
list_order_test() ->
    Set = ?set:from_binary(<<1:1, 0:7, 1:1, 0:7>>, 9),
    ?assertEqual([0,8], ?set:to_list(Set)).

%% Expect an empty list to be converted to an empty set
from_empty_list_test() ->
    Set0 = ?set:new(8),
    Set1 = ?set:from_list([], 8),
    ?assertEqual(Set0, Set1).

from_full_list_test() ->
    Set0 = ?set:from_binary(<<255:8>>, 8),
    Set1 = ?set:from_list(lists:seq(0,7), 8),
    ?assertEqual(Set0, Set1).

min_test_() ->
    [?_assertError(badarg, ?set:min(?set:new(20))),
     ?_assertEqual(0, ?set:min(?set:from_list([0], 8))),
     ?_assertEqual(1, ?set:min(?set:from_list([1,7], 8))),
     ?_assertEqual(15, ?set:min(?set:from_list([15], 16)))].

%%
%% Modifying the contents of a pieceset
%%

%% Piece indexes can never be less than zero.
negative_index_insert_test() ->
    ?assertError(badarg, ?set:insert(-1, undefined)).

%% Piece indexes should be within the range of the piece set
too_high_index_test() ->
    Set = ?set:new(8),
    ?assertError(badarg, ?set:insert(8, Set)).

%% The index of the last piece should work though
max_index_test() ->
    Set = ?set:new(8),
    ?assertMatch(_, ?set:insert(7, Set)).

%% Inserting a piece into a piece set should make it a member of the set
insert_min_test() ->
    Init = ?set:new(8),
    Set  = ?set:insert(0, Init),
    ?assert(?set:is_member(0, Set)),
    ?assertEqual(<<1:1, 0:7>>, ?set:to_binary(Set)).

insert_max_min_test() ->
    Init = ?set:new(5),
    Set  = ?set:insert(0, ?set:insert(4, Init)),
    ?assert(?set:is_member(4, Set)),
    ?assert(?set:is_member(0, Set)),
    ?assertEqual(<<1:1, 0:3, 1:1, 0:3>>, ?set:to_binary(Set)).

delete_invalid_index_test() ->
    Set = ?set:new(3),
    ?assertError(badarg, ?set:delete(-1, Set)),
    ?assertError(badarg, ?set:delete(3, Set)).

delete_test() ->
    Set = ?set:from_list([0,2], 3),
    ?assertNot(?set:is_member(0, ?set:delete(0, Set))),
    ?assertNot(?set:is_member(2, ?set:delete(2, Set))).

intersection_size_test() ->
    Set0 = ?set:new(5),
    Set1 = ?set:new(6),
    ?assertError(badarg, ?set:intersection(Set0, Set1)).

intersection_test() ->
    Set0  = ?set:from_binary(<<1:1, 0:7,      1:1, 0:7>>, 16),
    Set1  = ?set:from_binary(<<1:1, 1:1, 0:6, 1:1, 0:7>>, 16),
    Inter = ?set:intersection(Set0, Set1),
    Bitfield = <<1:1, 0:1, 0:6, 1:1, 0:7>>,
    ?assertEqual(Bitfield, ?set:to_binary(Inter)).

difference_size_test() ->
    Set0 = ?set:new(5),
    Set1 = ?set:new(6),
    ?assertError(badarg, ?set:difference(Set0, Set1)).

difference_test() ->
    Set0  = ?set:from_list([0,1,    4,5,6,7], 8),
    Set1  = ?set:from_list([  1,2,3,4,  6,7], 8),
    Inter = ?set:difference(Set0, Set1),
    ?assertEqual([0,5], ?set:to_list(Inter)).

%%
%% Conversion from piecesets to bitfields should produce valid bitfields.
%%

%% Starting from bit 0.
piece_0_test() ->
    Bitfield = <<1:1, 0:7>>,
    Set = ?set:from_binary(Bitfield, 8),
    ?assertEqual(Bitfield, ?set:to_binary(Set)).

%% Continuing into the second byte with piece 8.
piece_8_test() ->
    Bitfield = <<1:1, 0:7, 1:1, 0:7>>,
    Set = ?set:from_binary(Bitfield, 16),
    ?assertEqual(Bitfield, ?set:to_binary(Set)).

%% Preserving the original padding of the bitfield.
pad_binary_test() ->
    Bitfield = <<1:1, 1:1, 1:1, 0:5>>,
    Set = ?set:from_binary(Bitfield, 4),
    ?assertEqual(Bitfield, ?set:to_binary(Set)).


-ifdef(EQC).

prop_min() ->
    ?FORALL({Elem, Size},
    ?SUCHTHAT({E, S}, {nat(), nat()}, E < S andalso S > 1),
        Elem == ?set:min(?set:from_list([Elem], Size))).

prop_min_test() ->
    eqc:quickcheck(prop_min()).

-endif.
-endif.
