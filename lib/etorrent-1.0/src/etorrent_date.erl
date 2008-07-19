%%%-------------------------------------------------------------------
%%% File    : etorrent_date.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Library functions for date manipulation
%%%
%%% Created : 19 Jul 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------
-module(etorrent_date).

%% API
-export([
	 now_add/2, now_add_seconds/2,
	 now_subtract/2]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: now_subtract(NT, Millisecs) -> NT
%% Args:    NT ::= {Megasecs, Secs, Millisecs}
%%          Megasecs = Secs = Millisecs = integer()
%% Description: Subtract a time delta in millsecs from a now() triple
%%--------------------------------------------------------------------
now_subtract({_Megasecs, _Secs, _Millsecs}, _Sub) ->
    todo.

%%--------------------------------------------------------------------
%% Function: now_add(NT, Millisecs) -> NT
%% Args:    NT ::= {Megasecs, Secs, Millisecs}
%%          Megasecs = Secs = Millisecs = integer()
%% Description: Add a time delta in millsecs from a now() triple
%%--------------------------------------------------------------------
now_add({Megasecs, Secs, Millisecs}, Add) ->
    case Millisecs + Add of
	N when N < 1000 ->
	    {Megasecs, Secs, Millisecs + Add};
	N ->
	    case Secs + (N div 1000) of
		K when K < 1000000 ->
		    {Megasecs, K, N rem 1000};
		K ->
		    {Megasecs + (K div 1000000), (K rem 1000000), N rem 1000}
	    end
    end.

now_add_seconds({Megasecs, Secs, Millisecs}, Add) ->
    case Secs + Add of
	K when K < 1000000 ->
	    {Megasecs, K, Millisecs};
	K ->
	    {Megasecs + (K div 1000000), K rem 1000000, Millisecs}
    end.

%%====================================================================
%% Internal functions
%%====================================================================
