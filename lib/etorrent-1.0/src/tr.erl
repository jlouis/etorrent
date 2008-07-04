%%%-------------------------------------------------------------------
%%% File    : tr.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : tr - a simple tracer module based on dbg
%%%
%%% Created : 15 Jun 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(tr).

%% API
-export([tr/2, flush/0, client/0]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: tr(Module, Function)
%% Description: trace Module:Function
%%--------------------------------------------------------------------
tr(Module, Function) ->
    dbg:tpl(Module, Function, [{'_',[],[{return_trace}]}]).

flush() ->
    dbg:flush_trace_port().

client() ->
    dbg:trace_client(ip, {"localhost", 4711}).

%%====================================================================
%% Internal functions
%%====================================================================
