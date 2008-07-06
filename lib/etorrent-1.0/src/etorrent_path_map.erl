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
-export([select/1]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: select(Path) -> Id,
%%           select(Id)   -> Path
%% Description: Bi-directionally lookup on {Path, Id} pairs. If a non-
%%   exsisting path is selected, we add it as a side-effect
%%--------------------------------------------------------------------
select(Id) when is_integer(Id) ->
    [R] = mnesia:dirty_read(path_map, Id),
    R;
select(Path) when is_list(Path) ->
    case mnesia:dirty_index_read(path_map, Path, #path_map.path) of
	[] ->
	    Id = etorrent_sequence:next(path_map),
	    ok = mnesia:dirty_write(#path_map{ id = Id,
					       path = Path}),
	    Id;
	[R] ->
	    R#path_map.id
    end.

%%====================================================================
%% Internal functions
%%====================================================================
