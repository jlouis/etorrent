%%%-------------------------------------------------------------------
%%% File    : fs_filepiecemap.erl
%%% Author  : User Jlouis <jlouis@succubus.localdomain>
%%% License : See COPYING
%%% Description : Map pieces to files from torrents
%%%
%%% Created :  4 Feb 2007 by User Jlouis <jlouis@succubus.localdomain>
%%%-------------------------------------------------------------------
-module(fs_filepiecemap).

%% API
-export([new/1, lookup/2]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: new(Torrent) -> filepiecemap()
%% Description: Build a new mapping abstraction
%%--------------------------------------------------------------------
new(Torrent) ->
    {file_piece_map, construct_from(Torrent)}.

%%--------------------------------------------------------------------
%% Function: Lookup(Map, PieceNum) -> {piecelength,
%%                                      [{file(), num(), num()}]}
%% Description: Lookup a piece returning a list of filename, offset
%%   length triples for reading in the piece.
%%--------------------------------------------------------------------
lookup({file_piece_map, Map}, PieceNum) ->
    dict:fetch(Map, PieceNum).

%%====================================================================
%% Internal functions
%%====================================================================
construct_from(Torrent) ->
    {FilesAndSizes, Pieces} = cut_files_from_torrent(Torrent),
    List = build_file_map_list(FilesAndSizes, Pieces),
    dict:from_list(List).

%% Metainfo has tools for this
cut_files_from_torrent(T) ->
    ok.

%% Work on each piece
build_file_map_list(_FilesAndSizes, _NumberOfPieces) ->
    ok.

