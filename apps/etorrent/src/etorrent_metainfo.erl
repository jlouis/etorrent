%%%-------------------------------------------------------------------
%%% File    : metainfo.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus>
%%% License : See COPYING
%%% Description : Code for manipulating the metainfo file
%%%               Mostly for requests that are more complex
%%%
%%% Created : 24 Jan 2007 by Jesper Louis Andersen <jlouis@succubus>
%%%-------------------------------------------------------------------

-module(etorrent_metainfo).
-author("Jesper Louis Andersen <jesper.louis.andersen@gmail.com>").

-include("log.hrl").
-include("types.hrl").

-ifdef(TEST).
-include_lib("eqc/include/eqc.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
%% Metainfo
-export([get_piece_length/1, get_length/1, get_pieces/1, get_url/1,
         get_infohash/1,
         get_files/1, get_name/1,
         get_http_urls/1, get_udp_urls/1, get_dht_urls/1]).

%% ====================================================================
% @doc Search a torrent file, return the piece length
% @end
-spec get_piece_length(bcode()) -> integer().
get_piece_length(Torrent) ->
    etorrent_bcoding:get_info_value("piece length", Torrent).

% @doc Search a torrent for the length field
% @end
-spec get_length(bcode()) -> integer().
get_length(Torrent) ->
    case etorrent_bcoding:get_info_value("length", Torrent, none) of
	none -> sum_files(Torrent);
	I when is_integer(I) -> I
    end.

% @doc Search a torrent, return pieces as a list
% @end
-spec get_pieces(bcode()) -> [binary()].
get_pieces(Torrent) ->
    R = etorrent_bcoding:get_info_value("pieces", Torrent),
    split_into_chunks(R).

% @doc Return the URL of a torrent
% @end
-spec get_url(bcode()) -> [tier()].
get_url(Torrent) ->
    case etorrent_bcoding:get_value("announce-list", Torrent, none) of
	none -> U = etorrent_bcoding:get_value("announce", Torrent),
		[[binary_to_list(U)]];
	L when is_list(L) ->
	    [[binary_to_list(X) || X <- Tier] || Tier <- L]
    end.

filter_tiers(Torrent, P) ->
    F = fun(Tier) ->
		[U || U <- Tier, P(U)]
	end,
    Tiers = get_url(Torrent),
    [F(T) || T <- Tiers].

get_with_prefix(Torrent, P) ->
    filter_tiers(Torrent, fun(U) -> lists:prefix(P, U) end).

get_http_urls(Torrent) -> get_with_prefix(Torrent, "http://").
get_udp_urls(Torrent)  -> get_with_prefix(Torrent, "udp://").
get_dht_urls(Torrent)  -> get_with_prefix(Torrent, "dht://").

% @doc Return the infohash for a torrent
% @end
-spec get_infohash(bcode()) -> binary().
get_infohash(Torrent) ->
    Info = get_info(Torrent),
    crypto:sha(iolist_to_binary(etorrent_bcoding:encode(Info))).

% @doc Get a file list from the torrent
% @end
-spec get_files(bcode()) -> [{string(), integer()}].
get_files(Torrent) ->
    FilesEntries = get_files_section(Torrent),
    true = is_list(FilesEntries),
    [process_file_entry(Path) || Path <- FilesEntries].

% @doc Get the name of a torrent.
% @end
-spec get_name(bcode()) -> string().
get_name(Torrent) ->
    N = etorrent_bcoding:get_info_value("name", Torrent),
    true = valid_path(N),
    binary_to_list(N).

%% ====================================================================

get_file_length(File) ->
    etorrent_bcoding:get_value("length", File).

sum_files(Torrent) ->
    Files = etorrent_bcoding:get_info_value("files", Torrent),
    true = is_list(Files),
    lists:sum([get_file_length(F) || F <- Files]).

get_info(Torrent) ->
    etorrent_bcoding:get_value("info", Torrent).

split_into_chunks(<<>>) -> [];
split_into_chunks(<<Chunk:20/binary, Rest/binary>>) ->
    [Chunk | split_into_chunks(Rest)].

process_file_entry(Dict) ->
    F = etorrent_bcoding:get_value("path", Dict),
    Sz = etorrent_bcoding:get_value("length", Dict),
    true = lists:all(fun valid_path/1, F),
    Filename = filename:join([binary_to_list(X) || X <- F]),
    {Filename, Sz}.

get_files_section(Torrent) ->
    case etorrent_bcoding:get_info_value("files", Torrent, none) of
	none ->
	    % Single value torrent, fake entry
	    N = etorrent_bcoding:get_info_value("name", Torrent),
	    true = valid_path(N),
	    L = get_length(Torrent),
	    [[{<<"path">>, [N]},
	      {<<"length">>, L}]];
	V -> V
    end.


-ifdef(EUNIT).

test_torrent() ->
    [{<<"announce">>,
      <<"http://torrent.ubuntu.com:6969/announce">>},
     {<<"announce-list">>,
      [[<<"http://torrent.ubuntu.com:6969/announce">>],
       [<<"http://ipv6.torrent.ubuntu.com:6969/announce">>]]},
     {<<"comment">>,<<"Ubuntu CD releases.ubuntu.com">>},
     {<<"creation date">>,1286702721},
     {<<"info">>,
      [{<<"length">>,728754176},
       {<<"name">>,<<"ubuntu-10.10-desktop-amd64.iso">>},
       {<<"piece length">>,524288},
       {<<"pieces">>,
	<<34,129,182,214,148,202,7,93,69,98,198,49,204,47,61,
	  110>>}]}].

get_http_urls_test() ->
    ?assertEqual([["http://torrent.ubuntu.com:6969/announce"],
		  ["http://ipv6.torrent.ubuntu.com:6969/announce"]],
		 get_http_urls(test_torrent())).


-endif.



%%--------------------------------------------------------------------
%% Function: valid_path(Path)
%% Description: Predicate that tests the torrent only contains paths
%%   which are not a security threat. Stolen from Bram Cohen's original
%%   client.
%%--------------------------------------------------------------------
valid_path(Bin) when is_binary(Bin) -> valid_path(binary_to_list(Bin));
valid_path(Path) when is_list(Path) ->
    {ok, RM} = re:compile("^[^/\\.~][^\\/]*$"),
    case re:run(Path, RM) of
        {match, _} -> true;
        nomatch    -> false
    end.
