%%%-------------------------------------------------------------------
%%% File    : etorrent_file_logger.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Log to a file. Loosely based on log_mf_h from the
%%%  erlang distribution
%%%
%%% Created :  9 Jul 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_memory_logger).

-include("log.hrl").

-behaviour(gen_event).

-export([all_entries/0]).
-export([init/1, handle_event/2, handle_info/2, terminate/2]).
-export([handle_call/2, code_change/3]).

-record(state, {}).

-define(TAB, ?MODULE).

all_entries() ->
    ets:match_object(?TAB, '_').

%% =======================================================================

init(_Args) ->
    ets:new(?TAB, [named_table, protected]),
    {ok, #state{}}.

handle_event(Evt, S) ->
    Now = now(),
    ets:insert_new(?TAB, {Now, erlang:localtime(), Evt}),
    prune_old_events(),
    {ok, S}.

handle_info(_, State) ->
    {ok, State}.

terminate(_, _State) ->
    ok.

handle_call(null, State) ->
    {ok, null, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =======================================================================
%% @todo Implement prune_old_events
prune_old_events() ->
    ok.

