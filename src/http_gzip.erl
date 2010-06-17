%%%-------------------------------------------------------------------
%%% File    : http_gzip.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% Description : Wrapper around http to honor gzip.
%%%
%%% Created :  7 Aug 2007 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(http_gzip).

-include("etorrent_version.hrl").
%% API
-export([request/1]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: request/1
%% Description: As http:request/1 in the inets application, but also
%%   handles gzip. The request headers are explicitly handled to deal
%%   with badly and poorly implemented trackers (most of them)
%%--------------------------------------------------------------------
request(URL) ->
    case httpc:request(get, {URL, [{"User-Agent", ?AGENT_TRACKER_STRING},
                                   {"Host", decode_host(URL)},
                                   {"Accept", "*/*"},
                                   {"Accept-Encoding", "gzip, identity"}]},
                      [], [{headers_as_is, true}]) of
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
    LowerCaseHeaderKeys =
        [{string:to_lower(K), V} || {K, V} <- Headers],
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

decode_host(URL) ->
    {_Scheme, _UserInfo, Host, Port, _Path, _Query} =
        etorrent_http_uri:parse(URL),
    case Port of
        80 -> Host;
        N when is_integer(N) ->
            Host ++ ":" ++ integer_to_list(N)
    end.
