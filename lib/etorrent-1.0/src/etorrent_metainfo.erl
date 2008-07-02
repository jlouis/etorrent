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
-vsn(1).

%% API
-export([get_piece_length/1, get_length/1, get_pieces/1, get_url/1,
	 get_infohash/1,
	 get_files/1, get_name/1, hexify/1]).


%%====================================================================
%% API
%%====================================================================

%%--------------------------------------------------------------------
%% Function: get_piece_length/1
%% Description: Search a torrent file, return the piece length
%%--------------------------------------------------------------------
get_piece_length(Torrent) ->
    {integer, Size} =
	etorrent_bcoding:search_dict({string, "piece length"},
				     get_info(Torrent)),
    Size.

%%--------------------------------------------------------------------
%% Function: get_pieces/1
%% Description: Search a torrent, return pieces as a list
%%--------------------------------------------------------------------
get_pieces(Torrent) ->
    {string, Ps} = etorrent_bcoding:search_dict({string, "pieces"},
						get_info(Torrent)),
    [list_to_binary(S) || S <- split_into_chunks(20, Ps)].

get_length(Torrent) ->
    case etorrent_bcoding:search_dict({string, "length"},
				      get_info(Torrent)) of
	{integer, L} ->
	    L;
	false ->
	    %% Multifile torrent
	    sum_files(Torrent)
    end.

get_file_length(File) ->
    {integer, N} = etorrent_bcoding:search_dict({string, "length"},
						File),
    N.

sum_files(Torrent) ->
    {list, Files} = etorrent_bcoding:search_dict({string, "files"},
					get_info(Torrent)),
    lists:sum([get_file_length(F) || F <- Files]).

%%--------------------------------------------------------------------
%% Function: get_files/1
%% Description: Get a file list from the torrent
%%--------------------------------------------------------------------
get_files(Torrent) ->
    {list, FilesEntries} = get_files_section(Torrent),
    [process_file_entry(Path) || Path <- FilesEntries].

%%--------------------------------------------------------------------
%% Function: get_name/1
%% Description: Get the name of a torrent. Returns either {ok, N} for
%%   for a valid name or {error, security_violation, N} for something
%%   that violates the security limitations.
%%--------------------------------------------------------------------
get_name(Torrent) ->
    {string, N} = etorrent_bcoding:search_dict({string, "name"},
				      get_info(Torrent)),
    true = valid_path(N),
    N.

%%--------------------------------------------------------------------
%% Function: get_url/1
%% Description: Return the URL of a torrent
%%--------------------------------------------------------------------
get_url(Torrent) ->
    {string, U} = etorrent_bcoding:search_dict({string, "announce"},
					       Torrent),
    U.

%%--------------------------------------------------------------------
%% Function: get_infohash/1
%% Description: Return the infohash for a torrent
%%--------------------------------------------------------------------
get_infohash(Torrent) ->
    InfoDict = etorrent_bcoding:search_dict({string, "info"}, Torrent),
    InfoString = etorrent_bcoding:encode(InfoDict),
    crypto:sha(list_to_binary(InfoString)).


%%====================================================================
%% Internal functions
%%====================================================================
get_info(Torrent) ->
    etorrent_bcoding:search_dict({string, "info"}, Torrent).

split_into_chunks(_N, []) ->
    [];
split_into_chunks(N, String) ->
    {Chunk, Rest} = lists:split(N, String),
    [Chunk | split_into_chunks(N, Rest)].

hexify(Digest) ->
    lists:concat(
      [lists:concat(io_lib:format("~.16B", [C]))
       || C <- binary_to_list(Digest)]).

%%--------------------------------------------------------------------
%% Function: valid_path(Path)
%% Description: Predicate that tests the torrent only contains paths
%%   which are not a security threat. Stolen from Bram Cohen's original
%%   client.
%%--------------------------------------------------------------------
valid_path(Path) ->
    RE = "^[^/\\.~][^\\/]*$",
    case regexp:match(Path, RE) of
	{match, _S, _E} ->
	    true;
	nomatch ->
	    false
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
