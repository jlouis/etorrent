%%%-------------------------------------------------------------------
%%% File    : etorrent_torrent.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Library for manipulating the torrent table.
%%%
%%% Created : 15 Jun 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_torrent).

-include_lib("stdlib/include/qlc.hrl").
-include("etorrent_mnesia_table.hrl").

%% API
-export([new/2]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: 
%% Description:
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: new(Id, LoadData) -> transaction
%% Description: Initialyze a torrent entry for Id with the tracker
%%   state as given.
%%--------------------------------------------------------------------
new(Id, {{uploaded, U}, {downloaded, D}, {left, L}}) ->
    F = fun() ->
		mnesia:write(#torrent { id = Id,
					left = L,
					uploaded = U,
					downloaded = D,
					state = unknown })
	end,
    mnesia:transaction(F).

%%====================================================================
%% Internal functions
%%====================================================================
