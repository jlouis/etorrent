%%%-------------------------------------------------------------------
%%% File    : etorrent_piece_diskstate.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Manipulation of the #piece_diskstate table.
%%%
%%% Created : 16 Jul 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------
-module(etorrent_piece_diskstate).

-include_lib("stdlib/include/qlc.hrl").
-include("etorrent_mnesia_table.hrl").

%% API
-export([prune/1]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function:
%% Description:
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: prune/1 -> ok
%% Args: Filenames ::= set() (of filenames)
%% Description: Prune the table for any entry not in the FN set.
%%--------------------------------------------------------------------
prune(Filenames) ->
    {atomic, Kill} =
	mnesia:transaction(
	  fun () ->
		  Q = qlc:q([E#piece_diskstate.torrent
			     || E <- mnesia:table(piece_diskstate),
				sets:is_element(E#piece_diskstate.torrent,
						Filenames)]),
		  qlc:e(Q)
	  end),
    lists:foreach(fun (T) -> mnesia:dirty_delete(piece_diskstate, T) end,
		  Kill),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================
