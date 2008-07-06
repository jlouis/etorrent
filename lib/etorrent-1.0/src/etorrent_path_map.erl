%%%-------------------------------------------------------------------
%%% File    : etorrent_path_map.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Manipulate the #path_map table
%%%
%%% Created :  6 Jul 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_path_map).

-include_lib("stdlib/include/qlc.hrl").
-include("etorrent_mnesia_table.hrl").

%% API
-export([select/2, delete/1]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: select(Path) -> Id,
%%           select(Id)   -> Path
%% Description: Bi-directionally lookup on {Path, Id} pairs. If a non-
%%   exsisting path is selected, we add it as a side-effect
%%--------------------------------------------------------------------
select(Id, TorrentId) when is_integer(Id) ->
    [R] = mnesia:dirty_read(path_map, {Id, TorrentId}),
    R;
select(Path, TorrentId) when is_list(Path) ->
    case mnesia:dirty_index_read(path_map, Path, #path_map.path) of
	[] ->
	    Id = etorrent_sequence:next(path_map),
	    ok = mnesia:dirty_write(#path_map{ id = {Id, TorrentId},
					       path = Path}),
	    Id;
	[R] ->
	    {Id, _TorrentId} = R#path_map.id,
	    Id
    end.

%%--------------------------------------------------------------------
%% Function: delete(TorrentId) -> ok
%% Description: Delete entries from the pathmap based on the TorrentId
%%--------------------------------------------------------------------
delete(TorrentId) when is_integer(TorrentId) ->
    MatchHead = #path_map { id = {'_', TorrentId}, _ = '_' },
    [mnesia:delete_object(Obj) ||
	Obj <- mnesia:dirty_select(path_map, [{MatchHead, [], ['$_']}])].

%%====================================================================
%% Internal functions
%%====================================================================
