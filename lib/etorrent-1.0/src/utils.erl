%%%-------------------------------------------------------------------
%%% File    : utils.erl
%%% Author  : User Jlouis <jesper.louis.andersen@gmail.com>
%%% License : See COPYING
%%% Description : A selection of utilities used throughout the code
%%%
%%% Created : 17 Apr 2007 by User Jlouis <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(utils).

%% API
-export([read_all_of_file/1, list_tabulate/2, queue_remove/2,
	sets_is_empty/1, build_info_hash_encoded_form_rfc1738/1,
	build_uri_encoded_form_rfc1738/1]).

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
sets_is_empty(Set) ->
    case sets:size(Set) of
	0 ->
	    true;
	_ ->
	    false
    end.

queue_remove(Item, Q) ->
    QList = queue:to_list(Q),
    List = lists:delete(Item, QList),
    queue:from_list(List).

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
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.".

rfc_3986_unreserved_characters_set() ->
    sets:from_list(rfc_3986_unreserved_characters()).

build_uri_encoded_form_rfc1738(List) ->
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
		    List)).

build_info_hash_encoded_form_rfc1738(Binary) ->
    build_uri_encoded_form_rfc1738(binary_to_list(Binary)).





