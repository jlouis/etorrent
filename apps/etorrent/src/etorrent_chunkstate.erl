-module(etorrent_chunkstate).
%% This module implements the client interface to processes
%% tracking the state of chunk requests. This interface is
%% implemented by etorrent_progress, etorrent_pending and
%% etorrent_endgame. Each process type only handles a subset
%% each of these notifications.

-export([assigned/5,
         assigned/3,
         dropped/5,
         dropped/2,
         fetched/5,
         stored/5]).


%% @doc
%% @end
-spec assigned(non_neg_integer(), non_neg_integer(),
               non_neg_integer(), pid(), pid()) -> ok.
assigned(Piece, Offset, Length, Peerpid, Srvpid) ->
    Srvpid ! {chunk_assigned, Piece, Offset, Length, Peerpid},
    ok.


%% @doc
%% @end
-spec assigned([{non_neg_integer(), non_neg_integer(),
                 non_neg_integer()}], pid(), pid()) -> ok.
assigned(Chunks, Peerpid, Srvpid) ->
    [assigned(P, O, L, Peerpid, Srvpid) || {P, O, L} <- Chunks],
    ok.


%% @doc
%% @end
-spec dropped(non_neg_integer(), non_neg_integer(),
              non_neg_integer(), pid(), pid()) -> ok.
dropped(Piece, Offset, Length, Peerpid, Srvpid) ->
    Srvpid ! {chunk_dropped, Piece, Offset, Length, Peerpid},
    ok.


%% @doc
%% @end
-spec dropped([{non_neg_integer(), non_neg_integer(),
                non_neg_integer()}], pid(), pid()) -> ok.
dropped(Chunks, Peerpid, Srvpid) ->
    [dropped(P, O, L, Peerpid, Srvpid) || {P, O, L} <- Chunks],
    ok.


%% @doc
%% @end
-spec fetched(non_neg_integer(), non_neg_integer(),
                   non_neg_integer(), pid(), pid()) -> ok.
fetched(Piece, Offset, Length, Peerpid, Srvpid) ->
    Srvpid ! {chunk_fetched, Piece, Offset, Length, Peerpid},
    ok.


%% @doc
%% @end
-spec stored(non_neg_integer(), non_neg_integer(),
             non_neg_integer(), pid(), pid()) -> ok.
stored(Piece, Offset, Length, Peerpid, Srvpid) ->
    Srvpid ! {stored, Piece, Offset, Length, Peerpid},
    ok.

