%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Encode/Decode bcoded data.
%% <p>This module implements an optimistic bcoding encoder and
%% decoder. It is optimistic, because it will crash in the event that
%% an encoding can not be completed. The decoder decodes bcoded data
%% into normal, untagged erlang-terms. There is a slight important
%% point to make: The empty dict and the empty list is encoded as []
%% both. To make up for this, the encoder is augmented so it can
%% produce the right kind of construction if needed. Our code doesn't
%% really care there is a clash, but other, typed, clients might do.</p>
%% <p>The module is used practically all over etorrent, in every
%% creviche where it is necessary to encode or decode bcoded
%% string/binaries.</p>
%% <p>The decoder will silently ignore excess characters from a
%% decode. This is to fix errors with trackers which have errors in
%% their encoding.</p>
-module(etorrent_bcoding).
-author("Jesper Louis Andersen <jesper.louis.andersen@gmail.com>").

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
% Encoding and parsing
-export([encode/1, decode/1, parse_file/1]).

% Retrieval
-export([get_value/2, get_value/3, get_info_value/2, get_info_value/3,
         get_binary_value/2, get_binary_value/3,
	 get_string_value/2, get_string_value/3]).

-type bcode() :: etorrent_types:bcode().

%%====================================================================
%% API
%%====================================================================

%% @doc Encode a bcode structure to an iolist()
%%  two special-cases empty_list and empty_dict designates the difference
%%  between an empty list and dict for a client for which it matter. We don't
%%  care and take both to be []
%% @end
-spec encode(etorrent_types:bcode()) -> iolist().
encode(N) when is_integer(N) -> ["i", integer_to_list(N), "e"];
encode(B) when is_binary(B) -> [integer_to_list(byte_size(B)), ":", B];
encode({}) -> "de";
encode([{B,_}|_] = D) when is_binary(B) ->
    SortedD = lists:keysort(1, D),
    ["d", [[encode(K), encode(V)] || {K,V} <- SortedD], "e"];
encode([]) -> "le";
encode(L) when is_list(L) -> ["l", [encode(I) || I <- L], "e"].

%% @doc Decode a string or binary to a bcode() structure
%% @end
-spec decode(string() | binary()) -> {ok, bcode()} | {error, _Reason}.
decode(Bin) when is_binary(Bin) -> decode(binary_to_list(Bin));
decode(String) when is_list(String) ->
    try
        %% Don't check _Extra here. Some bcoding encoders fail to produce it
        %% correctly and adds garbage in the end.
        {Res, _Extra} = decode_b(String),
        {ok, Res}
    catch
        error:Reason -> {error, Reason}
    end.

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

%% @doc Get a value from the "info" part, with a Default
%%   the 'info' dictionary is expected to be present.
%% @end
get_info_value(Key, PL, Def) when is_list(Key) ->
    get_info_value(list_to_binary(Key), PL, Def);
get_info_value(Key, PL, Def) when is_binary(Key) ->
    PL2 = proplists:get_value(<<"info">>, PL),
    proplists:get_value(Key, PL2, Def).

%% @doc Read a binary Value indexed by Key from the PL dict
%% @end
get_binary_value(Key, PL) ->
    V = get_value(Key, PL),
    true = is_binary(V),
    V.

%% @doc Read a binary Value indexed by Key from the PL dict with default.
%%   <p>Will return Default upon non-existence</p>
%% @end
get_binary_value(Key, PL, Default) ->
    case get_value(Key, PL) of
	undefined -> Default;
	B when is_binary(B) -> B
    end.

%% @doc Read a string Value indexed by Key from the PL dict
%% @end
get_string_value(Key, PL) -> binary_to_list(get_binary_value(Key, PL)).

%% @doc Read a binary Value indexed by Key from the PL dict with default.
%%   <p>Will return Default upon non-existence</p>
%% @end
get_string_value(Key, PL, Default) ->
    case get_value(Key, PL) of
	undefined -> Default;
	V when is_binary(V) -> binary_to_list(V)
    end.

%% @doc Parse a file into a Torrent structure.
%% @end
-spec parse_file(string()) -> {ok, bcode()} | {error, _Reason}.
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
    decode_dict_items(String, []).

decode_dict_items([], Accum) ->
    {Accum, []};
decode_dict_items(String, Accum) ->
    case decode_b(String) of
        {end_of_data, Rest} when Accum == [] -> {{}, Rest};
        {end_of_data, Rest} -> {lists:reverse(Accum), Rest};
        {Key, Rest1} -> {Value, Rest2} = decode_b(Rest1),
                        decode_dict_items(Rest2, [{Key, Value} | Accum])
    end.

-ifdef(EUNIT).
-ifdef(PROPER).

prop_inv() ->
    ?FORALL(BC, bcode(),
            begin
		Enc = iolist_to_binary(encode(BC)),
		{ok, Dec} = decode(Enc),
		encode(BC) =:= encode(Dec)
            end).

eqc_test() ->
    ?assert(proper:quickcheck(prop_inv())).

-endif.
-endif.
