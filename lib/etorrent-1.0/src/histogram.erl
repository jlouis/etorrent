%%%-------------------------------------------------------------------
%%% File    : histogram.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Piece histograms.
%%%
%%% Created : 26 Jul 2007 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(histogram).

%% API
-export([new/0, increase_piece/2, decrease_piece/2,
	find_rarest_piece/2]).

-record(histogram, { piece_map = none,
		     histogram = none }).

%%====================================================================
%% API
%%====================================================================

%%--------------------------------------------------------------------
%% Function: new() -> histogram
%% Description: Create a new, empty histogram
%%--------------------------------------------------------------------
new() ->
    #histogram { piece_map = dict:new(),
		 histogram = gb_trees:empty() }.

%%--------------------------------------------------------------------
%% Function: increase_piece(PieceNum, histogram()) -> histogram()
%% Description: Increase the rarity of piece X by one.
%%--------------------------------------------------------------------
increase_piece(PieceNum, H) ->
    case dict:find(PieceNum, H#histogram.piece_map) of
	error ->
	    % No key there, so we should let it have rarity 1 and
	    % add it.
	    PM = dict:append(PieceNum, 1, H#histogram.piece_map),
	    Histogram =
		gb_tree_update_with_default(
		  1,
		  fun(S) ->
			  sets:add_element(PieceNum, S)
		  end,
		  sets:add_element(PieceNum, sets:new()),
		  H#histogram.histogram),
	    H#histogram{ piece_map = PM,
			 histogram = Histogram};
	{ok, Rarity} ->
	    PM = dict:update(PieceNum, fun(N) ->
					       N+1
				       end,
			    H#histogram.piece_map),
	    Histogram =
		gb_tree_update_with(
		  Rarity,
		  fun(S) ->
			  sets:del_element(PieceNum, S)
		  end,
		  H#histogram.histogram),
	    Histogram2 =
		gb_tree_update_with_default(
		  Rarity+1,
		  fun(S) ->
			  sets:add_element(PieceNum, S)
		  end,
		  sets:add_element(PieceNum, sets:new()),
		  Histogram),
	    H#histogram { piece_map = PM,
			  histogram = Histogram2 }
    end.

%%--------------------------------------------------------------------
%% Function: decrease_piece(PieceNum, histogram()) -> histogram()
%% Description: Decrease the availability of a piece.
%%--------------------------------------------------------------------
decrease_piece(PieceNum, H) ->
    case dict:find(PieceNum, H) of
	{ok, 1} ->
	    PM = dict:erase(PieceNum, H#histogram.piece_map),
	    Histogram =
		delete_if_empty(1,
				gb_tree_update_with(
				  1,
				  fun(S) ->
					  sets:del_element(PieceNum, S)
				  end,
				  H#histogram.histogram)),
	    H#histogram { piece_map = PM,
			  histogram = Histogram };
	{ok, Rarity} ->
	    PM = dict:update(PieceNum, fun(N) -> N-1 end,
			     H#histogram.piece_map),
	    Histogram =
		gb_tree_update_with(
		  Rarity,
		  fun(S) ->
			  sets:del_element(PieceNum, S)
		  end,
		  H#histogram.histogram),
	    Histogram2 =
		gb_tree_update_with_default(
		  Rarity-1,
		  fun(S) ->
			  sets:add_element(PieceNum, S)
		  end,
		  sets:add_element(PieceNum, sets:new()),
		  Histogram),
	    H#histogram { piece_map = PM,
			  histogram = Histogram2 }
    end.

%%--------------------------------------------------------------------
%% Function: find_rarest_piece(set(), histogram()) -> integer()
%% Description: Find the rarest piece among a set of eligible pieces
%%--------------------------------------------------------------------
find_rarest_piece(EligibleSet, Histogram) ->
    Iterator = gb_trees:iterator(Histogram),
    iterate_rarest_piece(gb_trees:next(Iterator), EligibleSet).

iterate_rarest_piece(none, _EligibleSet) ->
    none;
iterate_rarest_piece({_Key, Val, Iter2}, EligibleSet) ->
    Intersection = sets:intersection(Val, EligibleSet),
    case sets:is_empty(Intersection) of
	true ->
	    iterate_rarest_piece(gb_trees:next(Iter2), EligibleSet);
	false ->
	    Sz = sets:size(Intersection),
	    Random = crypto:rand_uniform(1, Sz+1),
	    lists:nth(Random, sets:to_list(Intersection))
    end.
%%--------------------------------------------------------------------
%% Function:
%% Description:
%%--------------------------------------------------------------------

%%====================================================================
%% Internal functions
%%====================================================================
delete_if_empty(Key, Histogram) ->
    case gb_tree:lookup(Key, Histogram) of
	{value, Set} ->
	    case sets:is_empty(Set) of
		true ->
		    gb_tree:delete(Key);
		false ->
		    Histogram
	    end
    end.

gb_tree_update_with(Key, Fun, GBTree) ->
    case gb_tree:lookup(Key, GBTree) of
	% Invariant, there is a key!
	{value, Set} ->
	    gb_tree:update(Key, Fun(Set), GBTree)
    end.

gb_tree_update_with_default(Key, Fun, Default, GBTree) ->
    case gb_tree:lookup(Key, GBTree) of
	none ->
	    gb_tree:enter(Key, Default, GBTree);
	{value, Set} ->
	    gb_tree:update(Key, Fun(Set), GBTree)
    end.
