%%%-------------------------------------------------------------------
%%% File    : etorrent_date.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Library functions for date manipulation
%%%
%%% Created : 19 Jul 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------
-module(etorrent_time).

%% API
-export([now_subtract_seconds/2]).

%% ====================================================================

% @doc Subtract a time delta in millsecs from a now() triple
% @end
-spec now_subtract_seconds({integer(), integer(), integer()}, integer()) ->
    {integer(), integer(), integer()}.
now_subtract_seconds({Megasecs, Secs, Ms}, Subsecs) ->
    case Secs - Subsecs of
        N when N >= 0 ->
            {Megasecs, N, Ms};
        N ->
            Needed = abs(N) div 1000000 + 1,
            {Megasecs - Needed, N + (Needed * 1000000), Ms}
    end.
