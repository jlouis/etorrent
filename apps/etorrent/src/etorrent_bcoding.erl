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
-include("types.hrl").
-include("log.hrl").

-ifdef(TEST).
-include_lib("eqc/include/eqc.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
% Encoding and parsing
-export([encode/1, decode/1, parse_file/1]).

% Retrieval
-export([get_value/2, get_value/3, get_info_value/2, get_info_value/3]).

%%====================================================================
%% API
%%====================================================================

%% @doc Encode a bcode structure to an iolist()
%%  two special-cases empty_list and empty_dict designates the difference
%%  between an empty list and dict for a client for which it matter. We don't
%%  care and take both to be []
%% @end
-spec encode(bcode() | empty_list | empty_dict) -> iolist().
encode(N) when is_integer(N) -> ["i", integer_to_list(N), "e"];
encode(B) when is_binary(B) -> [integer_to_list(byte_size(B)), ":", B];
encode(empty_dict) -> "de";
encode([{B,_}|_] = D) when is_binary(B) ->
    ["d", [[encode(K), encode(V)] || {K,V} <- D], "e"];
encode(empty_list) -> "le";
encode([]) -> exit(empty_list_in_bcode);
encode(L) when is_list(L) -> ["l", [encode(I) || I <- L], "e"].

%% @doc Decode a string or binary to a bcode() structure
%% @end
-spec decode(string() | binary()) -> bcode().
decode(Bin) when is_binary(Bin) -> decode(binary_to_list(Bin));
decode(String) when is_list(String) ->
    {Res, _Extra} = decode_b(String),
    Res.

%% @doc Get a value from the dictionary
%% @end
get_value(Key, PL) when is_list(Key) ->
    get_value(list_to_binary(Key), PL);
get_value(Key, PL) when is_binary(Key) ->
    proplists:get_value(Key, PL).

%% @doc Get a value from the dictionary returning Default on error
%% @end
get_value(Key, PL, Default) when is_list(Key) ->
    get_value(list_to_binary(Key), PL, Default);
get_value(Key, PL, Default) when is_binary(Key) ->
    proplists:get_value(Key, PL, Default).


%% @doc Get a value from the "info" part of the dictionary
%% @end
get_info_value(Key, PL) when is_list(Key) ->
    get_info_value(list_to_binary(Key), PL);
get_info_value(Key, PL) when is_binary(Key) ->
    PL2 = proplists:get_value(<<"info">>, PL),
    proplists:get_value(Key, PL2).

%% @doc Get a value from the "info" part of the dictionary, returning Default on err.
%%   the 'info' dictionary is expected to be present.
%% @end
get_info_value(Key, PL, Def) when is_list(Key) ->
    get_info_value(list_to_binary(Key), PL, Def);
get_info_value(Key, PL, Def) when is_binary(Key) ->
    PL2 = proplists:get_value(<<"info">>, PL),
    proplists:get_value(Key, PL2, Def).


%% @doc Parse a file into a Torrent structure.
%% @end
-spec parse_file(string()) -> bcode().
parse_file(File) ->
    {ok, Bin} = file:read_file(File),
    decode(Bin).

%%====================================================================
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
    {list_to_binary(StrData), Rest}.

decode_integer(String) ->
    {IntegerPart, RestPart} = lists:splitwith(charPred($e), String),
    {Int, _} = string:to_integer(IntegerPart),
    {Int, tl(RestPart)}.

decode_list(String) ->
    {ItemTree, Rest} = decode_list_items(String, []),
    {ItemTree, Rest}.

decode_list_items([], Accum) -> {lists:reverse(Accum), []};
decode_list_items(Items, Accum) ->
    case decode_b(Items) of
        {end_of_data, Rest} ->
            {lists:reverse(Accum), Rest};
        {I, Rest} -> decode_list_items(Rest, [I | Accum])
    end.

decode_dict(String) ->
    {Items, Rest} = decode_dict_items(String, []),
    {lists:reverse(Items), Rest}.

decode_dict_items([], Accum) ->
    {Accum, []};
decode_dict_items(String, Accum) ->
    case decode_b(String) of
        {end_of_data, Rest} -> {Accum, Rest};
        {Key, Rest1} -> {Value, Rest2} = decode_b(Rest1),
                        decode_dict_items(Rest2, [{Key, Value} | Accum])
    end.

-ifdef(EUNIT).
-ifdef(EQC).

dict() ->
    non_empty(list([{binary(), ?LAZY(bcode())}])).

bcode() ->
    ?SIZED(Sz,
	   oneof([int(),
		  non_empty(binary()),
		  resize(Sz div 4, non_empty(list(bcode()))),
		  resize(Sz div 4, dict())])).

prop_inv() ->
    ?FORALL(BC, bcode(),
	    begin
		Enc = iolist_to_binary(encode(BC)),
		Dec = decode(Enc),
		encode(BC) =:= encode(Dec)
	    end).

eqc_test() ->
    ?assert(eqc:quickcheck(prop_inv())).


-endif.
-endif.
