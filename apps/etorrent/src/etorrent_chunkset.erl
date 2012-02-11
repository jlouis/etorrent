-module(etorrent_chunkset).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([new/2,
         new/1,
         size/1,
         min/1,
         min/2,
         extract/2,
         is_empty/1,
         delete/2,
         delete/3,
         insert/3,
         from_list/3,
         in/3,
         subtract/3]).

-record(chunkset, {
    piece_len :: pos_integer(),
    chunk_len :: pos_integer(),
    chunks :: list({non_neg_integer(), pos_integer()})}).

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
        chunks=[{0, PieceLen - 1}]}.


%% @doc Create am empty copy of the chunkset.
new(Prototype) ->
    Prototype#chunkset{chunks=[]}.


from_list(PieceLen, ChunkLen, Chunks) ->
    #chunkset{
        piece_len=PieceLen,
        chunk_len=ChunkLen,
        chunks=Chunks}.

%% @doc
%% Get sum of the size of all chunks in the chunkset.
%% @end
-spec size(chunkset()) -> non_neg_integer().
size(Chunkset) ->
    #chunkset{chunks=Chunks} = Chunkset,
    Lengths = [1 + End - Start || {Start, End} <- Chunks],
    lists:sum(Lengths).

%% @doc
%% Get the offset and length of the chunk that is the closest
%% to the beginning of the piece. The chunk that is returned may
%% be shorter than the chunk length of the set.
%% @end
-spec min(chunkset()) -> {pos_integer(), pos_integer()}.
min(Chunkset) ->
    case min_(Chunkset) of
        none  -> erlang:error(badarg);
        Other -> Other
    end.

min_(Chunkset) ->
    #chunkset{chunk_len=ChunkLen, chunks=Chunks} = Chunkset,
    case Chunks of
        [] ->
            none;
        [{Start, End}|_] when (1 + End - Start) > ChunkLen ->
            {Start, ChunkLen};
        [{Start, End}|_] when (1 + End - Start) =< ChunkLen ->
            {Start, (End - Start) + 1}
    end.

%% @doc
%% Get at most N chunks from the beginning of the chunkset.
%% @end
min(_, Numchunks) when Numchunks < 1 ->
    erlang:error(badarg);
min(Chunkset, Numchunks) ->
    case min_(Chunkset, Numchunks) of
        [] -> erlang:error(badarg);
        List -> List
    end.

min_(_, 0) ->
    [];
min_(Chunkset, Numchunks) ->
    case min_(Chunkset) of
        none -> [];
        {Start, End}=Chunk ->
            Without = delete(Start, End, Chunkset),
            [Chunk|min_(Without, Numchunks - 1)]
    end.


%% @doc This operation combines min/2 and delete.
extract(Chunkset, Numchunks) when Numchunks >= 0 ->
    extract_(Chunkset, Numchunks, []).


extract_(Chunkset, 0, Acc) ->
    {lists:reverse(Acc), Chunkset};

extract_(Chunkset, Numchunks, Acc) ->
    case min_(Chunkset) of
        none -> 
            extract_(Chunkset, 0, Acc);

        {Start, End}=Chunk ->
            Without = delete(Start, End, Chunkset),
            extract_(Without, Numchunks - 1, [Chunk|Acc])
    end.



in(Offset, Size, Chunkset) ->
    NewChunkset = delete(Offset, Size, Chunkset),
    OldSize = ?MODULE:size(Chunkset),
    NewSize = ?MODULE:size(NewChunkset),
    Size =:= (OldSize - NewSize).


%% @doc This operation run `delete/3' and return result and 
%%      the list of the deleted values.
subtract(Offset, Length, Chunkset) when Length > 0, Offset >= 0 ->
    #chunkset{chunks=Chunks} = Chunkset,
    {NewChunks, Deleted} = sub_(Offset, Offset + Length - 1, Chunks, [], []),
    {Chunkset#chunkset{chunks=NewChunks}, rev_deleted_(Deleted, [])}.

%% E = S + L - 1.
%% L = E - S + 1.
rev_deleted_([{S, E}|T], Acc) ->
    L = E - S + 1,
    rev_deleted_(T, [{S, L}|Acc]);

rev_deleted_([], Acc) -> Acc.


sub_(CS, CE, [{S, E}=H|T], Res, Acc) 
    when is_integer(S), is_integer(CS), 
         is_integer(E), is_integer(CE) ->
    if
    CS =< S, CE =:= E ->
        % full match
        {lists:reverse(Res, T), [H|Acc]}; % H
    CS =< S, CE < E, CE > S ->
        % try delete smaller piece
        {lists:reverse(Res, [{CE+1, E}|T]), [{S, CE}|Acc]};
    CS =< S, CE < S ->
        % skip range
        {lists:reverse(Res, [H|T]), Acc};
    CS =< S, CE > E ->
        % try delete bigger piece
        sub_(E+1, CE, T, Res, [H|Acc]);
    CS > S, CE =:= E ->
        % try delete smaller piece
        {lists:reverse(Res, [{S, CS-1}|T]), [{CS, E}|Acc]};
    CS > S, CE < E ->
        % try delete smaller piece
        {lists:reverse(Res, [{S, CS-1},{CE+1, E}|T]), 
         [{CS, CE}|Acc]};
    CS > S, CS < E, CE > E ->
        % try delete bigger piece
        sub_(E+1, CE, T, [{S, CS-1}|Res], [{CS, E}|Acc]);
    CS > E ->
        % chunk is higher
        sub_(E+1, CE, T, [H|Res], Acc)
    end;
sub_(_CS, _CE, [], Res, Acc) ->
    {lists:reverse(Res), Acc}.
    

%% @doc Check is a chunkset is empty
%% @end
is_empty(Chunkset) ->
    #chunkset{chunks=Chunks} = Chunkset,
    Chunks == [].


%% @doc
%%
%% @end
delete([], Chunkset) ->
    Chunkset;
delete([{Offset, Length}|T], Chunkset) ->
    delete(T, delete(Offset, Length, Chunkset)).


insert([], Chunkset) ->
    Chunkset;
insert([{Offset, Length}|T], Chunkset) ->
    insert(T, insert(Offset, Length, Chunkset)).


%% @doc
%% 
%% @end
delete(Offset, Length, Chunkset) when Length < 1; Offset < 0 ->
    erlang:error(badarg);
delete(Offset, Length, Chunkset) ->
    #chunkset{chunks=Chunks} = Chunkset,
    NewChunks = delete_(Offset, Offset + Length - 1, Chunks),
    Chunkset#chunkset{chunks=NewChunks}.

delete_(_, _, []) ->
    [];
delete_(ChStart, ChEnd, [{Start, End}=H|T]) when ChStart =< Start ->
    if  ChEnd == End  -> T;
        ChEnd < Start -> [H|T];
        ChEnd < End   -> [{ChEnd + 1, End}|T];
        ChEnd > End   -> delete_(End, ChEnd, T)
    end;
delete_(ChStart, ChEnd, [{Start, End}|T]) when ChStart =< End ->
    if  ChStart == End -> [{Start, ChStart - 1}|delete_(End, ChEnd, T)];
        ChEnd   == End -> [{Start, ChStart - 1}|T];
        ChEnd   <  End -> [{Start, ChStart - 1},{ChEnd + 1, End}|T];
        ChEnd   >  End -> [{Start, ChStart - 1}|delete_(End, ChEnd, T)]
    end;
delete_(ChStart, ChEnd, [H|T]) ->
    [H|delete_(ChStart, ChEnd, T)].

%% @doc
%%
%% @end
insert(Offset, _, _) when Offset < 0 ->
    erlang:error(badarg);
insert(_, Length, _) when Length < 1 ->
    erlang:error(badarg);
insert(Offset, Length, Chunkset) ->
    #chunkset{piece_len=PieceLen, chunks=Chunks} = Chunkset,
    case (Offset + Length) > PieceLen of
        true ->
            erlang:error(badarg);
        false ->
            NewChunks = insert_(Offset, Offset + Length - 1, Chunks),
            Chunkset#chunkset{chunks=NewChunks}
    end.

insert_(ChStart, ChEnd, []) ->
    [{ChStart, ChEnd}];
insert_(ChStart, ChEnd, [{Start, _}|T]) when ChStart > Start ->
    insert_(Start, ChEnd, T);
insert_(ChStart, ChEnd, [{_, End}|T]) when ChEnd =< End ->
    [{ChStart, End}|T];
insert_(ChStart, ChEnd, [{_, End}|T]) when ChEnd > End ->
    insert_(ChStart, ChEnd, T).


-ifdef(TEST).
-define(set, ?MODULE).

new_test() ->
    Set = ?set:new(32, 2),
    ?assertEqual(32, ?set:size(Set)),
    ?assertEqual(?set:from_list(32, 2, [{0, 31}]), Set).

new_min_test() ->
    ?assertEqual({0, 2}, ?set:min(?set:new(32, 2))),
    ?assertEqual({0, 3}, ?set:min(?set:new(32, 3))).

min_smaller_test() ->
    Set = ?set:from_list(32, 4, [{0,1},{3, 31}]),
    ?assertEqual({0,2}, ?set:min(Set)).

min_empty_test() ->
    Set = ?set:from_list(32, 2, []),
    ?assertError(badarg, ?set:min(Set)).

min_zero_test() ->
    Set = ?set:from_list(2, 1, [{0,0}]),
    ?assertEqual({0,1}, ?set:min(Set)).

is_empty_test() ->
    Set = ?set:from_list(2, 1, []),
    ?assert(?set:is_empty(Set)).

not_is_empty_test() ->
    Set = ?set:from_list(2, 1, [{0,0}]),
    ?assertNot(?set:is_empty(Set)).

delete_invalid_length_test() ->
    ?assertError(badarg, ?set:delete(0, 0, ?set:new(32, 2))),
    ?assertError(badarg, ?set:delete(0, -1, ?set:new(32, 2))).

delete_invalid_offset_test() ->
    ?assertError(badarg, ?set:delete(-1, 1, ?set:new(32, 2))).

delete_empty_test() ->
    Set = ?set:from_list(32, 2, []),
    ?assertEqual(Set, ?set:delete(0, 1, Set)).

delete_head_test() ->
    Set0 = ?set:new(32, 2),
    Set1 = ?set:delete(0, 2, Set0),
    Set2 = ?set:delete(0, 3, Set1),
    ?assertEqual(?set:from_list(32, 2, [{2,31}]), Set1),
    ?assertEqual(?set:from_list(32, 2, [{3,31}]), Set2).

delete_head_size_test() ->
    Set = ?set:delete(0, 2, ?set:new(32, 2)),
    ?assertEqual(30, ?set:size(Set)).
    
delete_middle_test() ->
    Set0 = ?set:new(32, 2),
    Set1 = ?set:delete(2, 2, Set0),
    ?assertEqual(30, ?set:size(Set1)),
    ?assertEqual(?set:from_list(32, 2, [{0,1}, {4,31}]), Set1).

delete_end_test() ->
    Set0 = ?set:new(32, 2),
    Set1 = ?set:delete(30, 2, Set0),
    ?assertEqual(30, ?set:size(Set1)),
    ?assertEqual(?set:from_list(32, 2, [{0, 29}]), Set1).

delete_middle_range_test() ->
    Set0 = ?set:from_list(32, 2, [{0, 1}, {4,5}, {10, 31}]),
    Set1 = ?set:from_list(32, 2, [{0, 1}, {10, 31}]),
    ?assertEqual(Set1, ?set:delete(4, 2, Set0)),
    ?assertEqual(Set1, ?set:delete(3, 3, Set0)),
    ?assertEqual(Set1, ?set:delete(3, 4, Set0)).

delete_end_of_range_test() ->
    Set0 = ?set:from_list(32, 2, [{0, 5}, {10, 31}]),
    Set1 = ?set:from_list(32, 2, [{0, 3}, {10, 31}]),
    ?assertEqual(Set1, ?set:delete(4, 2, Set0)),
    ?assertEqual(Set1, ?set:delete(4, 3, Set0)).

delete_start_of_range_test() ->
    Set0 = ?set:from_list(32, 2, [{10, 31}]),
    Set1 = ?set:from_list(32, 2, [{12, 31}]),
    ?assertEqual(Set1, ?set:delete(8, 4, Set0)).

delete_last_byte_test() ->
    Set0 = ?set:from_list(32, 2, [{0, 5}, {10, 31}]),
    Set1 = ?set:from_list(32, 2, [{0, 4}, {10, 31}]),
    ?assertEqual(Set1, ?set:delete(5, 1, Set0)).


insert_invalid_offset_test() ->
    ?assertError(badarg, ?set:insert(-1, 0, undefined)).

insert_invalid_length_test() ->
    ?assertError(badarg, ?set:insert(0, 0, undefined)),
    ?assertError(badarg, ?set:insert(0, -1, undefined)).

insert_empty_test() ->
    Set0 = ?set:from_list(32, 2, []),
    Set1 = ?set:new(32, 2),
    ?assertEqual(Set1, ?set:insert(0, 32, Set0)).

insert_head_test() ->
    Set0 = ?set:from_list(32, 2, [{2, 31}]),
    Set1 = ?set:from_list(32, 2, [{0, 31}]),
    ?assertEqual(Set1, ?set:insert(0, 2, Set0)).

insert_after_head_test() ->
    Set0 = ?set:from_list(2,1,[]),
    Set1 = ?set:insert(0, 1, Set0),
    Set2 = ?set:insert(1, 1, Set1),
    Exp  = ?set:from_list(2,1,[{0,1}]),
    ?assertEqual(Exp, Set2).

insert_with_middle_test() ->
    Set0 = ?set:from_list(32, 2, [{0,1}, {3,4}, {6,31}]),
    Set1 = ?set:from_list(32, 2, [{0,31}]),
    ?assertEqual(Set1, ?set:insert(1, 6, Set0)).

insert_past_end_test() ->
    Set0 = ?set:new(32, 2),
    ?assertError(badarg, ?set:insert(0, 33, Set0)).

in_test_() ->
    Set0 = ?set:from_list(32, 2, [{0, 31}]),
    Set1 = ?set:from_list(32, 2, [{0, 10}, {20, 31}]),
    [ ?_assertEqual(true,  ?set:in(5, 6, Set0))
    , ?_assertEqual(true,  ?set:in(0, 32, Set0))
    , ?_assertEqual(false, ?set:in(0, 35, Set0))
    , ?_assertEqual(false, ?set:in(0, 55, Set0))

    , ?_assertEqual(true,  ?set:in(3, 4, Set1))
    , ?_assertEqual(false, ?set:in(10, 4, Set1))
    , ?_assertEqual(false, ?set:in(10, 21, Set1))
    , ?_assertEqual(false, ?set:in(0, 31, Set1))
    ].

subtract_test_() ->
    T0 = ?set:from_list(32, 2, [{10, 20}]),
    T1 = ?set:from_list(32, 2, [{10, 10}, {15, 20}]),
    T2 = ?set:from_list(32, 2, [{15, 20}]),
    [ ?_assertEqual(subtract(11, 4, T0), {T1, [{11,4}]})
    , ?_assertEqual(subtract(5, 10, T0), {T2, [{10,5}]})
    , ?_assertEqual(subtract(21, 5, T0), {T0, []})
    ].

-endif.
