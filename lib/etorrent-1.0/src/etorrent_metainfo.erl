%%%-------------------------------------------------------------------
%%% File    : metainfo.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus>
%%% License : See COPYING
%%% Description : Code for manipulating the metainfo file
%%%
%%% Created : 24 Jan 2007 by Jesper Louis Andersen <jlouis@succubus>
%%%-------------------------------------------------------------------

%% TODO: A couple of functions in metainfo doesn't belong here. They
%%   they should be moved into bcoding.

-module(etorrent_metainfo).
-author("Jesper Louis Andersen <jesper.louis.andersen@gmail.com>").
-vsn(1).

%% API
-export([getorrent_piece_length/1, getorrent_pieces/1, getorrent_url/1, getorrent_infohash/1,
	 parse/1, getorrent_files/1, getorrent_name/1, hexify/1]).

%%====================================================================
%% API
%%====================================================================

%%--------------------------------------------------------------------
%% Function: getorrent_piece_length/1
%% Description: Search a torrent file, return the piece length
%%--------------------------------------------------------------------
getorrent_piece_length(Torrent) ->
    {integer, Size} = find_target(getorrent_info(Torrent), "piece length"),
    Size.

%%--------------------------------------------------------------------
%% Function: getorrent_pieces/1
%% Description: Search a torrent, return pieces as a list
%%--------------------------------------------------------------------
getorrent_pieces(Torrent) ->
    case find_target(getorrent_info(Torrent), "pieces") of
	{string, Ps} ->
	    lists:map(fun(Str) -> list_to_binary(Str) end,
		      split_into_chunks(20, [], Ps))
    end.

getorrent_length(Torrent) ->
    case find_target(getorrent_info(Torrent), "length") of
	{integer, L} ->
	    L
    end.

%%--------------------------------------------------------------------
%% Function: getorrent_files/1
%% Description: Get a file list from the torrent
%%--------------------------------------------------------------------
getorrent_files(Torrent) ->
    case etorrent_bcoding:search_dict({string, "files"}, getorrent_info(Torrent)) of
	{ok, X} ->
	    X;
	false ->
	    % Single value torrent, fake entry
	    N = getorrent_name(Torrent),
	    L = getorrent_length(Torrent),
	    {list,[{dict,[{{string,"path"},
			   {list,[{string,N}]}},
			  {{string,"length"},{integer,L}}]}]}
    end.

%%--------------------------------------------------------------------
%% Function: getorrent_files/1
%% Description: Get the name of a torrent
%%--------------------------------------------------------------------
getorrent_name(Torrent) ->
    {string, N} = find_target(getorrent_info(Torrent), "name"),
    N.

%%--------------------------------------------------------------------
%% Function: getorrent_url/1
%% Description: Return the URL of a torrent
%%--------------------------------------------------------------------
getorrent_url(Torrent) ->
    case find_target(Torrent, "announce") of
	{string, U} -> U
    end.

%%--------------------------------------------------------------------
%% Function: getorrent_infohash/1
%% Description: Return the infohash for a torrent
%%--------------------------------------------------------------------
getorrent_infohash(Torrent) ->
    {ok, InfoDict} = etorrent_bcoding:search_dict({string, "info"}, Torrent),
    {ok, InfoString} = etorrent_bcoding:encode(InfoDict),
    crypto:sha(list_to_binary(InfoString)).

%%--------------------------------------------------------------------
%% Function: parse/1
%% Description: Parse a file into a Torrent structure.
%%--------------------------------------------------------------------
parse(File) ->
    case file:open(File, [read]) of
	{ok, IODev} ->
	    Data = read_data(IODev),
	    ok = file:close(IODev),
	    case etorrent_bcoding:decode(Data) of
		{ok, Torrent} ->
		    {ok, Torrent};
		{error, Reason} ->
		    {not_a_torrent, Reason}
	    end;
	{error, Reason} ->
	    {could_not_read_file, Reason}
    end.
%%====================================================================
%% Internal functions
%%====================================================================

%% Find a target that can't fail
find_target(D, Name) ->
    case etorrent_bcoding:search_dict({string, Name}, D) of
	{ok, X} ->
	    X
    end.

getorrent_info(Torrent) ->
    find_target(Torrent, "info").


split_into_chunks(_N, Accum, []) ->
    lists:reverse(Accum);
split_into_chunks(N, Accum, String) ->
    {Chunk, Rest} = lists:split(N, String),
    split_into_chunks(N, [Chunk | Accum], Rest).

read_data(IODev) ->
    eat_lines(IODev, []).

eat_lines(IODev, Accum) ->
    case io:get_chars(IODev, ">", 8192) of
	eof ->
	    lists:concat(lists:reverse(Accum));
	String ->
	    eat_lines(IODev, [String | Accum])
    end.

%% TODO: Implement the protocol for alternative URLs at some point.

hexify(Digest) ->
    Characters = lists:map(fun(Item) ->
				   lists:concat(io_lib:format("~.16B",
							      [Item])) end,
			   binary_to_list(Digest)),
    lists:concat(Characters).





