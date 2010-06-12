%%%-------------------------------------------------------------------
%%% File    : bcoding.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus>
%%% License : See COPYING
%%% Description : Functions for handling bcoded values
%%%
%%% Created : 24 Jan 2007 by Jesper Louis Andersen <jlouis@succubus>
%%%-------------------------------------------------------------------
-module(etorrent_bcoding).
-author("Jesper Louis Andersen <jesper.louis.andersen@gmail.com>").

-export([encode/1, decode/1, search_dict/2, search_dict_default/3,
        parse/1]).

-type bstring() :: {'string', string()}.
-type binteger() :: {'integer', integer()}.
-type bcode() :: bstring()
               | binteger()
               | {'list', [bcode()]}
               | {'dict', [{bstring(), bcode()}]}.

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: encode/1
%% Description: Encode an erlang term into a String
%%--------------------------------------------------------------------
-spec encode(bcode()) -> string().
encode(BString) ->
    case BString of
        {string, String} -> encode_string(String);
        {integer, Integer} -> encode_integer(Integer);
        {list, Items} -> encode_list([encode(I) || I <- Items]);
        {dict, Items} -> encode_dict(encode_dict_items(Items))
    end.

%%--------------------------------------------------------------------
%% Function: decode/1
%% Description: Decode a string to an erlang term.
%%--------------------------------------------------------------------
-spec decode(string()) -> bcode().
decode(String) ->
    {Res, E} = decode_b(String),
    case E of
        [] -> ok;
        X  -> error_logger:info_report([spurious_extra_decoded, X])
    end,
    Res.

%%--------------------------------------------------------------------
%% Function: search_dict/1
%% Description: Search the dict for a key. Returns the value or crashes.
%%--------------------------------------------------------------------
-type bdict() :: {'dict', [{bstring(), bcode()}]}.
-spec search_dict(bstring(), bdict()) -> false | bcode().
search_dict(Key, {dict, Elems}) ->
    case lists:keysearch(Key, 1, Elems) of
        {value, {_, V}} ->
            V;
        false ->
            false
    end.

-spec search_dict_default(bstring(), bdict(), X) -> bcode() | X.
search_dict_default(Key, Dict, Default) ->
    case search_dict(Key, Dict) of
        false ->
            Default;
        X ->
            X
    end.

%%--------------------------------------------------------------------
%% Function: parse/1
%% Description: Parse a file into a Torrent structure.
%%--------------------------------------------------------------------
-spec parse(string()) -> bcode().
parse(File) ->
    {ok, IODev} = file:open(File, [read]),
    Data = read_data(IODev),
    ok = file:close(IODev),
    decode(Data).

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
    lists:concat(["l", lists:concat(Items), "e"]).

encode_dict(Items) ->
    lists:concat(["d", lists:concat(Items), "e"]).

encode_dict_items([]) ->
    [];
encode_dict_items([{I1, I2} | Rest]) ->
    I = encode(I1),
    J = encode(I2),
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
    {Int, _} = string:to_integer(IntegerPart),
    {{integer, Int}, tl(RestPart)}.

decode_list(String) ->
    {ItemTree, Rest} = decode_list_items(String, []),
    {{list, ItemTree}, Rest}.

decode_list_items([], Accum) -> {lists:reverse(Accum), []};
decode_list_items(Items, Accum) ->
    case decode_b(Items) of
        {end_of_data, Rest} ->
            {lists:reverse(Accum), Rest};
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

read_data(IODev) ->
    eat_lines(IODev, []).

eat_lines(IODev, Accum) ->
    case io:get_chars(IODev, ">", 8192) of
        eof ->
            lists:concat(lists:reverse(Accum));
        String ->
            eat_lines(IODev, [String | Accum])
    end.
