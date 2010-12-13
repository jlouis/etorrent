-module(etorrent_pieceset).
-include("types.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([new/1,
         from_binary/2,
         to_binary/1,
         is_member/2,
         insert/2,
         intersection/2]).

-record(pieceset, {
    size :: pos_integer(),
    elements :: pos_integer()}).

%% @doc
%% Create an empty set of piece indexes. The set of pieces
%% is limited to contain pieces indexes from 0 to Size-1.
%% @end
new(Size) ->
    #pieceset{size=Size, elements=0}.

%% @doc
%% Create a piece set based on a bitfield. The bitfield is
%% expected to contain at most Size pieces. The piece set
%% returned by this function is limited to contain at most
%% Size pieces, as a set returned from new/1 is.
%% The bitfield is expected to not be padded with more than 7 bits.
%% @end
from_binary(Bin, Size) when is_binary(Bin) ->
    PaddingLen = paddinglen(Size),
    <<Elements:Size, PaddingValue:PaddingLen>> = Bin,
    %% All bits used for padding must be set to 0
    case PaddingValue of
        0 -> ok;
        _ -> error(badarg)
    end,
    #pieceset{size=Size, elements=Elements}.

%% @doc
%% Convert a piece set to a bitfield, the bitfield will
%% be padded with at most 7 bits set to zero.
%% @end
to_binary(Pieceset) ->
    #pieceset{size=Size, elements=Elements} = Pieceset,
    PaddingLen = paddinglen(Size),
    <<Elements:Size, 0:PaddingLen>>.

%% @doc
%% Returns true if the piece is a member of the piece set,
%% false if not. If the piece index is negative or is larger
%% than the size of this piece set, the function exits with badarg.
%% @end
is_member(PieceIndex, _) when PieceIndex < 0 ->
    error(badarg);
is_member(PieceIndex, Pieceset) ->
    #pieceset{size=Size, elements=Elements} = Pieceset,
    case PieceIndex < Size of
        false ->
            error(badarg);
        true ->
            (Elements band piecemask(PieceIndex, Size)) > 0
    end.

%% @doc
%% Insert a piece into the piece index. If the piece index is
%% negative or larger than the size of this piece set, this
%% function exists with the reason badarg.
%% @end
insert(PieceIndex, _) when PieceIndex < 0 ->
    error(badarg);
insert(PieceIndex, Pieceset) ->
    #pieceset{size=Size, elements=Elements} = Pieceset,
    case PieceIndex < Size of
        false ->
            error(badarg);
        true ->
            NewElements = Elements bor piecemask(PieceIndex, Size),
            Pieceset#pieceset{elements=NewElements}
    end.

%% @doc
%% Return a piece set where each member is a member of both sets.
%% If both sets are not of the same size this function exits with badarg.
%% @end
intersection(Set0, Set1) ->
    #pieceset{size=Size0, elements=Elements0} = Set0,
    #pieceset{size=Size1, elements=Elements1} = Set1,
    case Size0 == Size1 of
        false ->
            error(badarg);
        true ->
            Intersection = Elements0 band Elements1,
            #pieceset{size=Size0, elements=Intersection}
    end.
    
    

piecemask(PieceIndex, Size) ->
    1 bsl (Size - PieceIndex - 1).

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

-endif.
