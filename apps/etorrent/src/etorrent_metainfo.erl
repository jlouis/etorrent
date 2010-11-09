%%%-------------------------------------------------------------------
%%% File    : metainfo.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus>
%%% License : See COPYING
%%% Description : Code for manipulating the metainfo file
%%%
%%% Created : 24 Jan 2007 by Jesper Louis Andersen <jlouis@succubus>
%%%-------------------------------------------------------------------

-module(etorrent_metainfo).
-author("Jesper Louis Andersen <jesper.louis.andersen@gmail.com>").

-include("types.hrl").

%% API
-export([get_piece_length/1, get_length/1, get_pieces/1, get_url/1,
         get_infohash/1,
         get_files/1, get_name/1,
         get_http_urls/1, get_udp_urls/1, get_dht_urls/1]).


%% ====================================================================

% @doc Search a torrent file, return the piece length
% @end
-spec get_piece_length(bcode()) -> integer().
get_piece_length(Torrent) ->
    {integer, Size} =
        etorrent_bcoding:search_dict({string, "piece length"},
                                     get_info(Torrent)),
    Size.

% @doc Search a torrent for the length field
% @end
-spec get_length(bcode()) -> integer().
get_length(Torrent) ->
    case etorrent_bcoding:search_dict({string, "length"},
                                      get_info(Torrent)) of
        {integer, L} ->
            L;
        false ->
            %% Multifile torrent
            sum_files(Torrent)
    end.

% @doc Search a torrent, return pieces as a list
% @end
-spec get_pieces(bcode()) -> [binary()].
get_pieces(Torrent) ->
    {string, Ps} = etorrent_bcoding:search_dict({string, "pieces"},
                                                get_info(Torrent)),
    [list_to_binary(S) || S <- split_into_chunks(Ps)].

% @doc Return the URL of a torrent
% @end
-type tier() :: [string()].
-spec get_url(bcode()) -> [tier()].
get_url(Torrent) ->
    case etorrent_bcoding:search_dict({string, "announce-list"}, Torrent) of
	{list, Elems} ->
	    decode_announce_urls(Elems);
	false ->
	    {string, U} = etorrent_bcoding:search_dict({string, "announce"},
						       Torrent),
	    [[U]]
    end.

-spec get_with_prefix(bcode(), string()) -> string().
get_with_prefix(Torrent, P) ->
    [[U || U <- T, lists:prefix(P, U)] || T <- get_url(Torrent)].

-spec get_http_urls(bcode()) -> string().
get_http_urls(Torrent) ->
    get_with_prefix(Torrent, "http://").

-spec get_udp_urls(bcode()) -> string().
get_udp_urls(Torrent) ->
    get_with_prefix(Torrent, "udp://").

-spec get_dht_urls(bcode()) -> string().
get_dht_urls(Torrent) ->
    get_with_prefix(Torrent, "dht://").

% @doc Return the infohash for a torrent
% @end
-spec get_infohash(bcode()) -> binary().
get_infohash(Torrent) ->
    InfoDict = etorrent_bcoding:search_dict({string, "info"}, Torrent),
    InfoString = etorrent_bcoding:encode(InfoDict),
    crypto:sha(list_to_binary(InfoString)).

% @doc Get a file list from the torrent
% @end
-spec get_files(bcode()) -> [{string(), integer()}].
get_files(Torrent) ->
    {list, FilesEntries} = get_files_section(Torrent),
    [process_file_entry(Path) || Path <- FilesEntries].

% @doc Get the name of a torrent.
% <p>Returns either {ok, N} for for a valid name or {error, security_violation,
% N} for something that violates the security limitations.</p>
% @end
-spec get_name(bcode()) -> string().
get_name(Torrent) ->
    {string, N} = etorrent_bcoding:search_dict({string, "name"},
                                      get_info(Torrent)),
    true = valid_path(N),
    N.

%% ====================================================================

get_file_length(File) ->
    {integer, N} = etorrent_bcoding:search_dict({string, "length"},
                                                File),
    N.

sum_files(Torrent) ->
    {list, Files} = etorrent_bcoding:search_dict({string, "files"},
                                        get_info(Torrent)),
    lists:sum([get_file_length(F) || F <- Files]).

get_info(Torrent) ->
    etorrent_bcoding:search_dict({string, "info"}, Torrent).

split_into_chunks(L) -> split_into_chunks(20, L).

split_into_chunks(_N, []) -> [];
split_into_chunks(N, String) ->
    {Chunk, Rest} = lists:split(N, String),
    [Chunk | split_into_chunks(N, Rest)].

%%--------------------------------------------------------------------
%% Function: valid_path(Path)
%% Description: Predicate that tests the torrent only contains paths
%%   which are not a security threat. Stolen from Bram Cohen's original
%%   client.
%%--------------------------------------------------------------------
valid_path(Path) ->
    {ok, RM} = re:compile("^[^/\\.~][^\\/]*$"),
    case re:run(Path, RM) of
        {match, _} -> true;
        nomatch    -> false
    end.

process_file_entry(Entry) ->
    {dict, Dict} = Entry,
    {value, {{string, "path"},
             {list, Path}}} =
        lists:keysearch({string, "path"}, 1, Dict),
    {value, {{string, "length"},
             {integer, Size}}} =
        lists:keysearch({string, "length"}, 1, Dict),
    true = lists:any(fun({string, P}) -> valid_path(P) end, Path),
    Filename = filename:join([X || {string, X} <- Path]),
    {Filename, Size}.

get_files_section(Torrent) ->
    case etorrent_bcoding:search_dict({string, "files"}, get_info(Torrent)) of
        false ->
            % Single value torrent, fake entry
            N = get_name(Torrent),
            L = get_length(Torrent),
            {list,[{dict,[{{string,"path"},
                           {list,[{string,N}]}},
                          {{string,"length"},{integer,L}}]}]};
        V -> V
    end.

decode_announce_urls(Tiers) ->
    [ decode_tier(Tier) || {list, Tier} <- Tiers ].

decode_tier(Urls) ->
    [U || {string, U} <- Urls].
