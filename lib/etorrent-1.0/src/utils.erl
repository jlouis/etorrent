%%%-------------------------------------------------------------------
%%% File    : utils.erl
%%% Author  : User Jlouis <jlouis@succubus.localdomain>
%%% Description : A selection of utilities used throughout the code
%%%
%%% Created : 17 Apr 2007 by User Jlouis <jlouis@succubus.localdomain>
%%%-------------------------------------------------------------------
-module(utils).

%% API
-export([read_all_of_file/1, list_tabulate/2]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: read_all_of_file: File -> {ok, Data} | {error, Reason}
%% Description: Open and read all data from File.
%%--------------------------------------------------------------------
read_all_of_file(File) ->
    case file:open(File, [read]) of
	{ok, IODev} ->
	    {ok, read_data(IODev)};
	{error, Reason} ->
	    {error, Reason}
    end.

list_tabulate(N, F) ->
    list_tabulate(0, N, F, []).

%%====================================================================
%% Internal functions
%%====================================================================

list_tabulate(N, K, _F, Acc) when N ==K ->
    lists:reverse(Acc);
list_tabulate(N, K, F, Acc) ->
    list_tabulate(N+1, K, F, [F(N) | Acc]).

read_data(IODev) ->
    eat_lines(IODev, []).

eat_lines(IODev, Accum) ->
    case io:get_chars(IODev, ">", 8192) of
	eof ->
	    lists:concat(lists:reverse(Accum));
	String ->
	    eat_lines(IODev, [String | Accum])
    end.
