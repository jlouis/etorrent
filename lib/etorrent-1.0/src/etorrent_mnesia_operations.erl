%%%-------------------------------------------------------------------
%%% File    : etorrent_mnesia_operations.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Various mnesia operations
%%%
%%% Created : 25 Mar 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_mnesia_operations).

-include_lib("stdlib/include/qlc.hrl").

-include("etorrent_mnesia_table.hrl").


%% API
-export([new_torrent/2]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: new_torrent(Filename, Supervisor) -> ok
%% Description: Add a new torrent given by File with the Supervisor
%%   pid as given to the database structure.
%%--------------------------------------------------------------------
new_torrent(File, Supervisor) ->
    T = fun () ->
		mnesia:write(#tracking_map { filename = File,
					     supervisor_pid = Supervisor })
	end,
    ok = mnesia:transaction(T).

%%--------------------------------------------------------------------
%% Function: 
%% Description:
%%--------------------------------------------------------------------


%%====================================================================
%% Internal functions
%%====================================================================
