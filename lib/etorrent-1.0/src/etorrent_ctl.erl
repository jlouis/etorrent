%%%-------------------------------------------------------------------
%%% File    : etorrent_ctl.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Controller. Called from a distributed node towards etorrent
%%%
%%% Created :  3 Jul 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_ctl).

%% API
-export([start/1, process/1]).

-define(STATUS_OK, 0).
-define(STATUS_BADRPC, 1).
-define(STATUS_USAGE, 2).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start() -> ok
%% Description: This is the command which is run to control etorrent
%%--------------------------------------------------------------------
start (Args) ->
    case parse_arguments(Args) of
	{Node, Commands} ->
	    Status = case rpc:call(Node, ?MODULE, process, [Commands]) of
			 {badrpc, Reason} ->
			     io:format("RPC failed on node ~p: ~p~n",
				       [Node, Reason]),
			     ?STATUS_BADRPC;
			 S ->
			     S
		     end,
	    halt(Status);
	_ ->
	    halt(?STATUS_USAGE)
    end.

%%====================================================================
%% Internal functions
%%====================================================================
process([stop]) ->
    etorrent:stop(),
    ?STATUS_OK;
process([list]) ->
    etorrent:list(),
    ?STATUS_OK;
process([help]) ->
    etorrent:help(),
    ?STATUS_USAGE;
process([_]) ->
    etorrent:help(),
    ?STATUS_USAGE.


parse_arguments([Node | Cmds]) ->
    {Node,
     Cmds}.

