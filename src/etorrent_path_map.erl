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
-export([select/2, populate_entry/2, delete/1]).

%% ====================================================================
% @doc Bi-directionally lookup on {Path, Id} pairs.
% <p>If a non-exsisting path is selected, we add it as a side-effect</p>
% @end
% @todo is the second variant here called at all?
-spec select(integer(), integer()) -> #path_map{}.
select(Id, TorrentId) when is_integer(Id) ->
    [R] = mnesia:dirty_read(path_map, {Id, TorrentId}),
    R.

% @doc Populate the #path_map table with entries. Return the Id
% <p>If the path-map entry is already there, its Id is returned straight
% away.</p>
% @end
-spec populate_entry(string(), integer()) -> {value, integer()}.
populate_entry(Path, TorrentId) ->
    case mnesia:dirty_index_read(path_map, Path, #path_map.path) of
        [] ->
            Id = etorrent_counters:next(path_map),
            PM = #path_map { id = {Id, TorrentId}, path = Path},
            ok = mnesia:dirty_write(PM),
            {value, Id};
        [#path_map { id = {Id, _} }] ->
            {value, Id}
    end.

% @doc Delete entries from the pathmap based on the TorrentId
% @end
-spec delete(integer()) -> ok.
delete(TorrentId) when is_integer(TorrentId) ->
    MatchHead = #path_map { id = {'_', TorrentId}, _ = '_' },
    lists:foreach(fun(Obj) -> mnesia:dirty_delete_object(Obj) end,
                  mnesia:dirty_select(path_map, [{MatchHead, [], ['$_']}])),
    ok.
