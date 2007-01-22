-module(torrent_piecemap).
-behaviour(gen_server).

-export([start_link/1, init/1, handle_call/3, handle_cast/2, code_change/3, handle_info/2]).
-export([terminate/2]).

start_link(Amount) ->
    gen_server:start_link(torrent_piecemap, Amount, []).

init(NumberOfPieces) ->
    PieceTable = initialize_piece_table(NumberOfPieces),
    {A, B, C} = erlang:now(),
    random:seed(A, B, C),
    {ok, PieceTable}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_info(Info, State) ->
    error_logger:info_report([{'INFO', Info}, {'State', State}]),
    {noreply, State}.

terminate(shutdown, _Piecemap) ->
    ok.

initialize_piece_table(Amount) ->
    Table = ets:new(piece_table, []),
    populate_table(Table, Amount).

populate_table(Table, 0) ->
    Table;
populate_table(Table, N) ->
    ets:insert(Table, {N, unclaimed}),
    populate_table(Table, N-1).

handle_call({request_piece, PiecesPeerHas}, Who, PieceTable) ->
    case find_appropriate_piece(PieceTable, Who, PiecesPeerHas) of
	{ok, P} ->
	    {reply, {piece_to_get, P}};
	none_applies ->
	    {reply, no_pieces_are_interesting}
    end.

handle_cast({peer_got_piece, _PieceNum}, PieceTable) ->
    {noreply, PieceTable}. %% This can later be used for rarest first selection


find_appropriate_piece(PieceTable, Who, PiecesPeerHas) ->
    case find_eligible_pieces(PiecesPeerHas, PieceTable) of
	{ok, Pieces} ->
	    P = pick_random(Pieces),
	    mark_as_requested(PieceTable, P, Who),
	    {ok, P};
	none ->
	    none_applies
    end.

mark_as_requested(PieceTable, PNum, Who) ->
    ets:insert(PieceTable, {PNum, Who}).

find_eligible_pieces(PiecesPeerHas, PieceTable) ->
    Unclaimed = sets:from_list(ets:select(PieceTable, [{{'$1', unclaimed}, [], ['$1']}])),
    Eligible = sets:intersection(Unclaimed, PiecesPeerHas),
    EligibleSize = sets:size(Eligible),
    if
	EligibleSize > 0 ->
	    {ok, Eligible};
	true ->
	    none
    end.

pick_random(PieceSet) ->
    Size = sets:size(PieceSet),
    lists:nth(random:uniform(Size), sets:to_list(PieceSet)).


