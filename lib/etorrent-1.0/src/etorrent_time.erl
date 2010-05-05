%%%-------------------------------------------------------------------
%%% File    : etorrent_date.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Library functions for date manipulation
%%%
%%% Created : 19 Jul 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------
-module(etorrent_time).

%% API
-export([now_add_seconds/2, now_subtract_seconds/2]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: now_subtract(NT, Millisecs) -> NT
%% Args:    NT ::= {Megasecs, Secs, Millisecs}
%%          Megasecs = Secs = Millisecs = integer()
%% Description: Subtract a time delta in millsecs from a now() triple
%%--------------------------------------------------------------------
now_subtract_seconds({Megasecs, Secs, Ms}, Subsecs) ->
    case Secs - Subsecs of
        N when N >= 0 ->
            {Megasecs, N, Ms};
        N ->
            Needed = abs(N) div 1000000 + 1,
            {Megasecs - Needed, N + (Needed * 1000000), Ms}
    end.

now_add_seconds({Megasecs, Secs, Ms}, Add) ->
    case Secs + Add of
        K when K < 1000000 ->
            {Megasecs, K, Ms};
        K ->
            {Megasecs + K div 1000000, K rem 1000000, Ms}
    end.

%%====================================================================
%% Internal functions
%%====================================================================
