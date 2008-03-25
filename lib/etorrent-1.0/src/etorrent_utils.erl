%%%-------------------------------------------------------------------
%%% File    : etorrent_utils.erl
%%% Author  : User Jlouis <jesper.louis.andersen@gmail.com>
%%% License : See COPYING
%%% Description : A selection of utilities used throughout the code
%%%
%%% Created : 17 Apr 2007 by User Jlouis <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_utils).

%% API
-export([read_all_of_file/1, list_tabulate/2, queue_remove/2,
	 queue_remove_with_check/2, sets_is_empty/1,
	 build_encoded_form_rfc1738/1]).

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

%%--------------------------------------------------------------------
%% Function: sets_is_empty(set()) -> bool()
%% Description: True if set() is empty, false otherwise
%%--------------------------------------------------------------------
sets_is_empty(Set) ->
    case sets:size(Set) of
	0 ->
	    true;
	_ ->
	    false
    end.

%%--------------------------------------------------------------------
%% Function: queue_remove_with_check(Item, Q1) -> {ok, Q2} | false
%% Description: If Item is present in queue(), remove the first
%%   occurence and return it as {ok, Q2}. If the item can not be found
%%   return false.
%%   Note: Inefficient implementation. Converts to/from lists.
%%--------------------------------------------------------------------
queue_remove_with_check(Item, Q) ->
    QList = queue:to_list(Q),
    case lists:member(Item, QList) of
	true ->
	    List = lists:delete(Item, QList),
	    {ok, queue:from_list(List)};
	false ->
	    false
    end.

%%--------------------------------------------------------------------
%% Function: queue_remove(Item, queue()) -> queue()
%% Description: Remove first occurence of Item in queue() if present.
%%   Note: This function assumes the representation of queue is opaque
%%     and thus the function is quite ineffective. We can build a much
%%     much faster version if we create our own queues.
%%--------------------------------------------------------------------
queue_remove(Item, Q) ->
    QList = queue:to_list(Q),
    List = lists:delete(Item, QList),
    queue:from_list(List).

%%--------------------------------------------------------------------
%% Function: build_encoded_form_rfc1738(list() | binary()) -> String
%% Description: Convert the list into RFC1738 encoding (URL-encoding).
%%--------------------------------------------------------------------
build_encoded_form_rfc1738(List) when is_list(List) ->
    Unreserved = rfc_3986_unreserved_characters_set(),
    lists:flatten(lists:map(
		    fun (E) ->
			    case sets:is_element(E, Unreserved) of
				true ->
				    E;
				false ->
				    lists:concat(
				      ["%", io_lib:format("~2.16.0B", [E])])
			    end
		    end,
		    List));
build_encoded_form_rfc1738(Binary) when is_binary(Binary) ->
    build_encoded_form_rfc1738(binary_to_list(Binary)).

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

rfc_3986_unreserved_characters() ->
    % jlouis: I deliberately killed ~ from the list as it seems the Mainline
    %  client doesn't announce this.
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_./".

rfc_3986_unreserved_characters_set() ->
    sets:from_list(rfc_3986_unreserved_characters()).






