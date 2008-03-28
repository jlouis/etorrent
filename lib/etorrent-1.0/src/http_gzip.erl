%%%-------------------------------------------------------------------
%%% File    : http_gzip.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% Description : Wrapper around http to honor gzip.
%%%
%%% Created :  7 Aug 2007 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(http_gzip).

%% API
-export([request/1]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: request/1
%% Description: As http:request/1 in the inets application, but also
%%   handles gzip.
%%--------------------------------------------------------------------
request(URL) ->
    case http:request(get, {URL, [{"Accept-Encoding", "gzip identity"}]},
		      [], []) of
	{ok, {{Version, StatusCode, ReasonPhrase}, Headers, Body}} ->
	    case decode_content_encoding(Headers) of
		identity ->
		    {ok, {{Version, StatusCode, ReasonPhrase}, Headers, Body}};
		gzip ->
		    DecompressedBody = binary_to_list(zlib:gunzip(Body)),
		    {ok, {{Version, StatusCode, ReasonPhrase}, Headers,
		     DecompressedBody}}
	    end;
	E ->
	    E
    end.

%%====================================================================
%% Internal functions
%%====================================================================
decode_content_encoding(Headers) ->
    LowerCaseHeaderKeys = lists:map(fun({K, V}) ->
					    {string:to_lower(K), V}
				    end,
				    Headers),
    case lists:keysearch("content-encoding", 1, LowerCaseHeaderKeys) of
	{value, {_, "gzip"}} ->
	    gzip;
	{value, {_, "deflate"}} ->
	    deflate;
	{value, {_, "identity"}} ->
	    identity;
	false ->
	    identity
    end.
