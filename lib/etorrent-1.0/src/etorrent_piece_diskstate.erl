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
-export([new/2, prune/1, select/1]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function:
%% Description:
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: new/2 -> ok
%% Args: Filename ::= string() (filename of torrent)
%%       State ::= seeding | {bitfield, BF}
%%
%%       BF ::= binary() (bitfield)
%% Description: Add/Update the Filenames persistent disk state
%%--------------------------------------------------------------------
new(Filename, State) ->
    mnesia:dirty_write(#piece_diskstate { filename = Filename,
                                          state = State }).

%%--------------------------------------------------------------------
%% Function: prune/1 -> ok
%% Args: Filenames ::= set() (of filenames)
%% Description: Prune the table for any entry not in the FN set.
%%--------------------------------------------------------------------
prune(Filenames) ->
    {atomic, Kill} =
        mnesia:transaction(
          fun () ->
                  Q = qlc:q([E#piece_diskstate.filename
                             || E <- mnesia:table(piece_diskstate),
                                sets:is_element(E#piece_diskstate.filename,
                                                Filenames)]),
                  qlc:e(Q)
          end),
    lists:foreach(fun (T) -> mnesia:dirty_delete(piece_diskstate, T) end,
                  Kill),
    ok.

%%--------------------------------------------------------------------
%% Function: select/1
%% Args: Filename ::= string()
%% Description: Select the row matching the filename
%%--------------------------------------------------------------------
select(FN) ->
    mnesia:dirty_read(piece_diskstate, FN).

%%====================================================================
%% Internal functions
%%====================================================================
