%%%-------------------------------------------------------------------
%%% File    : etorrent_mnesia_histogram.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Mnesia Histogram manipulation code
%%%
%%% Created : 20 Apr 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------
-module(etorrent_mnesia_histogram).


-include_lib("stdlib/include/qlc.hrl").
-include("etorrent_mnesia_table.hrl").

%% API
-export([increase_piece/2, decrease_piece/2, find_rarest_piece/2,
	 remote_bitfield/2, remove_bitfield/2]).

%%====================================================================
%% API
%%====================================================================

%%--------------------------------------------------------------------
%% Function: remote_bitfield(Pid, PieceSet) -> {atomic, ok} | transaction aborted
%% Description: Add a complete PieceSet to the histogram
%%--------------------------------------------------------------------
remote_bitfield(Pid, PieceSet) ->
    sets:fold(fun(P, _) ->
		      {atomic, _} = increase_piece(Pid, P),
		      ok
	      end,
	      ok,
	      PieceSet).

%%--------------------------------------------------------------------
%% Function: remove_bitfield(Pid, PieceSet) -> {atomic, ok} | transaction aborted
%% Description: Remove a complete PieceSet fro mthe histogram
%%--------------------------------------------------------------------
remove_bitfield(Pid, PieceSet) ->
    sets:fold(fun(P, _) ->
		      {atomic, _} = decrease_piece(Pid, P),
		      ok
	      end,
	      ok,
	      PieceSet).

%%--------------------------------------------------------------------
%% Function: increase_piece(Pid, PieceNum) -> {atomic, ok} | transaction aborted
%% Description: Increase the frequency of PieceNum for torrent referenced
%%   by Pid
%%--------------------------------------------------------------------
increase_piece(Pid, PieceNum) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([S || S <- mnesia:table(file_access),
			      S#file_access.pid =:= Pid,
			      S#file_access.piece_number =:= PieceNum]),
	      [R] = qlc:e(Q),
	      case R#file_access.frequency of
		  0 ->
		      mnesia:write(R#file_access { frequency = 1 }),
		      ok = add_histogram(Pid, PieceNum, 1),
		      ok;
		  N when is_integer(N) ->
		      mnesia:write(
			R#file_access { frequency = R#file_access.frequency + 1 }),
		      ok = add_histogram(Pid, PieceNum, R#file_access.frequency + 1),
		      ok = remove_histogram(Pid, PieceNum, R#file_access.frequency),
		      ok
	      end
      end).

%%--------------------------------------------------------------------
%% Function: decrease_piece(Pid, PieceNum) -> {atomic, ok} | transaction aborted
%% Description: Decrease the frequency of PieceNum for torrent referenced
%%   by Pid
%%--------------------------------------------------------------------
decrease_piece(Pid, PieceNum) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([S || S <- mnesia:table(file_access),
			      S#file_access.pid =:= Pid,
			      S#file_access.piece_number =:= PieceNum]),
	      [R] = qlc:e(Q),
	      case R#file_access.frequency of
		  1 ->
		      mnesia:write(R#file_access{ frequency = 0 }),
		      remove_histogram(Pid, PieceNum, 1),
		      ok;
		  N when is_integer(N) ->
		      mnesia:write(R#file_access{ frequency =
						    R#file_access.frequency - 1 }),
		      remove_histogram(Pid, PieceNum, R#file_access.frequency),
		      add_histogram(Pid, PieceNum, R#file_access.frequency - 1),
		      ok
	      end
      end).

%%--------------------------------------------------------------------
%% Function: find_rarest_piece(Pid, Eligible) -> {atomic, Piece} | trans. abort
%% Description: Find the rarest piece amongst a set of eligible pieces
%%--------------------------------------------------------------------
find_rarest_piece(Pid, EligibleSet) ->
    mnesia:transaction(
      fun () ->
	      Q1 = qlc:q([R || R <- mnesia:table(histogram),
			       R#histogram.pid =:= Pid]),
	      Cursor = qlc:cursor(qlc:keysort(3, Q1)),
	      Res = find_eligible(Cursor, EligibleSet),
	      qlc:delete_cursor(Cursor),
	      Res
      end).

%%====================================================================
%% Internal functions
%%====================================================================
find_eligible(Cursor, EligibleSet) ->
    case qlc:next_answers(Cursor, 1) of
	[] ->
	    error_logger:info_report(none_eligible),
	    none_eligible;
	[R] ->
	    Intersection = sets:intersection(EligibleSet, R#histogram.entries),
	    case sets:size(Intersection) of
		0 ->
		    find_eligible(Cursor, EligibleSet);
		N when is_integer(N) ->
		    Random = crypto:rand_uniform(1, N+1),
		    {ok, lists:nth(Random, sets:to_list(Intersection))}
	    end
    end.

add_histogram(Pid, PieceNum, Frequency) ->
    Q1 = qlc:q([R || R <- mnesia:table(histogram),
		     R#histogram.pid =:= Pid,
		     R#histogram.frequency =:= Frequency]),
    case qlc:e(Q1) of
	[] ->
	    mnesia:write(#histogram { ref = make_ref(),
				      pid = Pid,
				      frequency = Frequency,
				      entries = sets:add_element(PieceNum, sets:new()) }),
	    ok;
	[S] ->
	    mnesia:write(S#histogram { entries = sets:add_element(PieceNum,
								  S#histogram.entries)}),
	    ok
    end.


remove_histogram(Pid, PieceNum, Frequency) ->
    Q1 = qlc:q([R || R <- mnesia:table(histogram),
		     R#histogram.pid =:= Pid,
		     R#histogram.frequency =:= Frequency]),
    case qlc:e(Q1) of
	[S] ->
	    NewSet = sets:del_element(PieceNum, S#histogram.entries),
	    case sets:size(NewSet) of
		0 ->
		    mnesia:delete_object(S),
		    ok;
		N when is_integer(N) ->
		    mnesia:write(S#histogram { entries = NewSet }),
		    ok
	    end
    end.
