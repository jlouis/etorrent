%%%-------------------------------------------------------------------
%%% File    : etorrent_sequence.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Manipulation of the #sequence table
%%%
%%% Created :  6 Jul 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_sequence).

%% API
-export([next/1]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: next(Sequence) -> Id
%% Description: Return the next element from sequence Sequence.
%%--------------------------------------------------------------------
next(Sequence) ->
    mnesia:dirty_update_counter(sequence, Sequence, 1).

%%====================================================================
%% Internal functions
%%====================================================================
