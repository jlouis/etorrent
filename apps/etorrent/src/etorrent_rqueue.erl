%% @author Magnus Klaar <magnus.klaar@gmail.com>
%% @doc Request queue for peers
%% This module provides a wrapper for the queue module from stdlib, it
%% assumes that responses to chunk requests are delivered in the same
%% order as they were sent.
%%
%% The module provides additional functions for validating incoming
%% requests against the head of the queue. We want to verify that the
%% piece, offset and chunk length matches. We also want to be able to
%% detect if the piece and offset but not the chunk length matches.
%%
%% The module also provides additional functions for checking if the
%% request pipeline needs to be refilled or not. The thresholds are
%% encapsulated in the request queue.
%% @end
-module(etorrent_rqueue).

-export([new/0,
         new/2,
         push/4,
         pop/1,
         peek/1,
         size/1,
         is_head/4,
         has_offset/3,
         is_low/1,
         needs/1]).


-type pieceindex() :: etorrent_types:piece_index().
-type chunkoffset() :: non_neg_integer().
-type chunklength() :: pos_integer().
-type requestspec() :: {pieceindex(), chunkoffset(), chunklength()}.

-record(requestqueue, {
    low_limit  :: non_neg_integer(),
    high_limit :: pos_integer(),
    queue :: queue()}).
-opaque requestqueue() :: #requestqueue{}.


%% @doc Create an empty request queue with default pipeline thresholds
%% @end
-spec new() -> requestqueue().
new() ->
    new(2, 10).


%% @doc Create an empty request queue and specify pipeline thresholds
%% @end
-spec new(non_neg_integer(), pos_integer()) -> requestqueue().
new(Lowthreshold, Highthreshold) ->
    InitQueue = #requestqueue{
        low_limit=Lowthreshold,
        high_limit=Highthreshold,
        queue=queue:new()},
    InitQueue.


%% @doc
%% @end
-spec push(pieceindex(), chunkoffset(),
           chunklength(), #requestqueue{}) -> requestqueue().
push(Pieceindex, Offset, Length, Requestqueue) ->
    #requestqueue{queue=Queue} = Requestqueue,
    NewQueue = queue:in({Pieceindex, Offset, Length}, Queue),
    Requestqueue#requestqueue{queue=NewQueue}.


%% @doc
%% @end
-spec pop(#requestqueue{}) -> {requestspec(), requestqueue()}.
pop(Requestqueue) ->
    #requestqueue{queue=Queue} = Requestqueue,
    case queue:out(Queue) of
        {empty, _} ->
            error(badarg);
        {{value, Head}, Tail} ->
            {Head, Tail}
    end.


%% @doc
%% @end
-spec peek(#requestqueue{}) -> false | requestspec().
peek(Requestqueue) ->
    #requestqueue{queue=Queue} = Requestqueue,
    case queue:is_empty(Queue) of
        true  -> false;
        false -> queue:get(Queue)
    end.


%% @doc
%% @end
-spec size(#requestqueue{}) -> non_neg_integer().
size(Requestqueue) ->
    #requestqueue{queue=Queue} = Requestqueue,
    queue:len(Queue).


%% @doc Check if a request is at the head of the request queue
%% @end
-spec is_head(pieceindex(), chunkoffset(),
              chunklength(), #requestqueue{}) -> boolean().
is_head(Pieceindex, Offset, Length, Requestqueue) ->
    Req = {Pieceindex, Offset, Length},
    case peek(Requestqueue) of
        false -> false;
        Req   -> true;
        _     -> false
    end.


%% @doc Check if the offset of a request matches the head of the queue
%% @end
-spec has_offset(pieceindex(), chunkoffset(), #requestqueue{}) -> boolean().
has_offset(Pieceindex, Offset, Requestqueue) ->
    I = Pieceindex,
    O = Offset,
    case peek(Requestqueue) of
        false   -> false;
        {I,O,_} -> true;
        _       -> false
    end.


%% @doc Check if the number or open requests is below the pipeline threshold
%% @end
-spec is_low(#requestqueue{}) -> boolean().
is_low(Requestqueue) ->
    #requestqueue{low_limit=Low, queue=Queue} = Requestqueue,
    queue:len(Queue) =< Low.


%% @doc
%% @end
-spec needs(#requestqueue{}) -> non_neg_integer().
needs(Requestqueue) ->
    #requestqueue{high_limit=High, queue=Queue} = Requestqueue,
    Length = queue:len(Queue),
    case Length < High of
        true  -> High - Length;
        false -> 0
    end.


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(rqueue, etorrent_rqueue).

empty_test_() ->
    Q0 = ?rqueue:new(),
    [?_assertEqual(0, ?rqueue:size(Q0)),
     ?_assertError(badarg, ?rqueue:pop(Q0)),
     ?_assertEqual(false, ?rqueue:peek(Q0)),
     ?_assertNot(?rqueue:is_head(0, 0, 0, Q0)),
     ?_assertNot(?rqueue:has_offset(0, 0, Q0))].

one_request_test_() ->
    Q0 = ?rqueue:new(),
    Q1 = ?rqueue:push(0, 0, 1, Q0),
    {Req, Q2} = ?rqueue:pop(Q1),
    [?_assertEqual(1, ?rqueue:size(Q1)),
     ?_assertEqual({0,0,1}, ?rqueue:peek(Q1)),
     ?_assertEqual({0,0,1}, Req)].

head_check_test_() ->
    Q0 = ?rqueue:new(),
    Q1 = ?rqueue:push(1, 2, 3, Q0),
    [?_assertNot(?rqueue:is_head(1, 2, 3, Q0)),
     ?_assert(?rqueue:is_head(1, 2, 3, Q1)),
     ?_assertNot(?rqueue:is_head(1, 2, 2, Q1)),
     ?_assertNot(?rqueue:is_head(1, 2, 4, Q1)),
     ?_assert(?rqueue:has_offset(1, 2, Q1)),
     ?_assertNot(?rqueue:has_offset(0, 2, Q1)),
     ?_assertNot(?rqueue:has_offset(1, 1, Q1))].

low_check_test_() ->
    Q0 = ?rqueue:new(1, 3),
    Q1 = ?rqueue:push(0, 0, 1, Q0),
    Q2 = ?rqueue:push(0, 1, 1, Q1),
    [?_assert(?rqueue:is_low(Q0)),
     ?_assert(?rqueue:is_low(Q1)),
     ?_assertNot(?rqueue:is_low(Q2))].

needs_test_() ->
    Q0 = ?rqueue:new(1, 3),
    Q1 = ?rqueue:push(0, 0, 1, Q0),
    Q2 = ?rqueue:push(0, 1, 1, Q1),
    Q3 = ?rqueue:push(0, 2, 1, Q2),
    Q4 = ?rqueue:push(0, 3, 1, Q3),
    [?_assertEqual(3, ?rqueue:needs(Q0)),
     ?_assertEqual(2, ?rqueue:needs(Q1)),
     ?_assertEqual(1, ?rqueue:needs(Q2)),
     ?_assertEqual(0, ?rqueue:needs(Q3)),
     ?_assertEqual(0, ?rqueue:needs(Q4))].


-endif.

