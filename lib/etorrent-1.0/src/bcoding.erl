%%%-------------------------------------------------------------------
%%% File    : bcoding.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus>
%%% License : See COPYING
%%% Description : Functions for handling bcoded values
%%%
%%% Created : 24 Jan 2007 by Jesper Louis Andersen <jlouis@succubus>
%%%-------------------------------------------------------------------
-module(bcoding).
-author("Jesper Louis Andersen <jesper.louis.andersen@gmail.com>").
-vsn("1.0").

%% API
-export([encode/1, decode/1, search_dict/2, search_dict_default/3]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: encode/1
%% Description: Encode an erlang term into a String
%%--------------------------------------------------------------------
encode(BString) ->
    case BString of
	{string, String} ->
	    {ok, encode_string(String)};
	{integer, Integer} ->
	    {ok, encode_integer(Integer)};
	{list, Items} ->
	    EncodedItems = lists:map(fun (I) ->
					     {ok, Item} = encode(I),
					     Item
				     end, Items),
	    {ok, encode_list(EncodedItems)};
	{dict, Items} ->
	    EncodedItems = encode_dict_items(Items),
	    {ok, encode_dict(EncodedItems)};
	_ ->
	    {error, "Not a bencoded structure"}
    end.

%%--------------------------------------------------------------------
%% Function: decode/1
%% Description: Decode a string to an erlang term.
%%--------------------------------------------------------------------
decode(String) ->
    case decode_b(String) of
	{Res, []} ->
	    {ok, Res};
	E ->
	    {error, E}
    end.

%%--------------------------------------------------------------------
%% Function: search_dict/1
%% Description: Search the dict for a key. Returns {ok, Val} or false.
%%   if the bastard is not a dict, return not_a_dict.
%%--------------------------------------------------------------------
search_dict(Key, Dict) ->
    case Dict of
	{dict, Elems} ->
	    case lists:keysearch(Key, 1, Elems) of
		{value, {_, V}} ->
		    {ok, V};
		false ->
		    false
	    end;
	_ ->
	    not_a_dict
    end.

search_dict_default(Key, Dict, Default) ->
    case bcoding:search_dict(Key, Dict) of
	{ok, Val} ->
	    Val;
	_ ->
	    Default
    end.

%%====================================================================
%% Internal functions
%%====================================================================

%% Encode a string.
encode_string(Str) ->
    L = length(Str),
    lists:concat([L, ':', Str]).

encode_integer(Int) ->
    lists:concat(['i', Int, 'e']).

encode_list(Items) ->
    error_logger:error_msg("Items ~p~n", [Items]),
    lists:concat(["l", lists:concat(Items), "e"]).

encode_dict(Items) ->
    lists:concat(["d", lists:concat(Items), "e"]).

encode_dict_items([]) ->
    [];
encode_dict_items([{I1, I2} | Rest]) ->
    {ok, I} = encode(I1),
    {ok, J} = encode(I2),
    [I, J | encode_dict_items(Rest)].

decode_b([]) ->
    empty_string;
decode_b([H | Rest]) ->
    case H of
	$i ->
	    decode_integer(Rest);
	$l ->
	    decode_list(Rest);
	$d ->
	    decode_dict(Rest);
	$e ->
	    {end_of_data, Rest};
	S ->
	    %% This might fail, and so what ;)
	    attempt_string_decode([S|Rest])
    end.

charPred(C) ->
    fun(E) ->
	    E /= C end.

attempt_string_decode(String) ->
    {Number, Data} = lists:splitwith(charPred($:), String),
    {ParsedNumber, _} = string:to_integer(Number),
    Rest1 = tl(Data),
    {StrData, Rest} = lists:split(ParsedNumber, Rest1),
    {{string, StrData}, Rest}.

decode_integer(String) ->
    {IntegerPart, RestPart} = lists:splitwith(charPred($e), String),
    case string:to_integer(IntegerPart) of
	{Int, _} ->
	    {{integer, Int}, tl(RestPart)}
    end.

decode_list(String) ->
    {ItemTree, Rest} = decode_list_items(String, []),
    {{list, lists:reverse(ItemTree)}, Rest}.

decode_list_items([], Accum) -> {Accum, []};
decode_list_items(Items, Accum) ->
    case decode_b(Items) of
	{end_of_data, Rest} ->
	    {Accum, Rest};
	{I, Rest} -> decode_list_items(Rest, [I | Accum])
    end.

decode_dict(String) ->
    {Items, Rest} = decode_dict_items(String, []),
    {{dict, lists:reverse(Items)}, Rest}.

decode_dict_items([], Accum) ->
    {Accum, []};
decode_dict_items(String, Accum) ->
    case decode_b(String) of
	{end_of_data, Rest} ->
	    {Accum, Rest};
	{Key, Rest1} -> {Value, Rest2} = decode_b(Rest1),
			decode_dict_items(Rest2, [{Key, Value} | Accum])
    end.

