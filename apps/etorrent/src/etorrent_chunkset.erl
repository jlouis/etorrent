-module(etorrent_chunkset).
-include("types.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([new/2,
         size/1]).

-record(chunkset, {
    piece_len :: pos_integer(),
    chunk_len :: pos_integer(),
    chunks :: list({pos_integer(), pos_integer()})}).

-opaque chunkset() :: #chunkset{}.
-export_type([chunkset/0]).

%% @doc
%% Create a set of chunks for a piece.
%% @end
-spec new(pos_integer(), pos_integer()) -> chunkset().
new(PieceLen, ChunkLen) ->
    #chunkset{
        piece_len=PieceLen,
        chunk_len=ChunkLen,
        chunks=[{0, PieceLen}]}.

%% @doc
%% Get sum of the size of all chunks in the chunkset.
%% @end
size(Chunkset) ->
    #chunkset{chunks=Chunks} = Chunkset,
    Lengths = [Len || {_, Len} <- Chunks],
    lists:sum(Lengths).


-ifdef(TEST).
-define(set, ?MODULE).

new_size_test() ->
    ?assertEqual(32, ?set:size(?set:new(32, 2))).

-endif.
