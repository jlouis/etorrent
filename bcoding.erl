%%%-------------------------------------------------------------------
%%% File    : bcoding.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus>
%%% Description : 
%%%
%%% Created : 27 Dec 2006 by Jesper Louis Andersen <jlouis@succubus>
%%%-------------------------------------------------------------------
-module(bcoding).

-export([encode/1, decode/1]).

-author('jesper.louis.andersen@gmail.com').


encode_string(Str) ->
    L = length(Str),
    lists:concat([L, ':', Str]).

encode_integer(Int) ->
    lists:concat(['i', Int, 'e']).

encode_list(Items) ->
    lists:concat(["l", lists:concat(Items), "e"]).

encode_dict(Items) ->
    lists:concat(["d", lists:concat(Items), "e"]).

encode(BString) ->
    case BString of
	{string, String} ->
	    {ok, encode_string(String)};
	{integer, Integer} ->
	    {ok, encode_integer(Integer)};
	{list, Items} ->
	    EncodedItems = lists:map(encode, Items),
	    {ok, encode_list(EncodedItems)};
	{dict, Items} ->
	    EncodedItems = lists:map(encode, Items),
	    {ok, encode_dict(EncodedItems)};
	_ ->
	    {error, "Not a bencoded structure"}
    end.

decode(String) ->
    case decode_b(String) of
	{Res, []} ->
	    {ok, Res};
	_ ->
	    {error, "There was data after the bcoded structure"}
    end.

decode_b([]) ->
    {empty_string, "Empty String"};
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
    {{list, ItemTree}, Rest}.

decode_list_items([], Accum) -> {Accum, []};
decode_list_items(Items, Accum) ->
    case decode_b(Items) of
	{end_of_data, Rest} ->
	    {Accum, Rest};
	{I, Rest} -> decode_list_items(Rest, [I | Accum])
    end.

decode_dict(String) ->
    {Items, Rest} = decode_dict_items(String, []),
    {{dict, Items}, Rest}.

decode_dict_items([], Accum) ->
    {Accum, []};
decode_dict_items(String, Accum) ->
    case decode_b(String) of
	{end_of_data, Rest} ->
	    {Accum, Rest};
	{Key, Rest1} -> {Value, Rest2} = decode_b(Rest1),
			decode_list_items(Rest2, [{Key, Value} | Accum])
    end.

%% Search the Dict for Key. Returns {ok, Val} or false. If We are not searching
%  a dict, return not_a_dict.
search_dict(Dict, Key) ->
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

