-module(etorrent_download).

-export([peerhandle/1,
         update/2,
         request_chunks/3,
         mark_dropped/4,
         mark_fetched/4,
         mark_stored/4]).

-type torrent_id()  :: etorrent_types:torrent_id().
-type pieceset()    :: etorrent_pieceset:pieceset().
-type pieceindex()  :: etorrent_types:pieceindex().
-type chunkoffset() :: etorrent_types:chunkoffset().
-type chunklength() :: etorrent_types:chunklength().
-type chunkspec()   :: {pieceindex(), chunkoffset(), chunklength()}.

-record(peerhandle, {
    torrent_id :: torrent_id(),
    in_endgame :: boolean(),
    pending    :: etorrent_pending:peerhandle(),
    progress   :: etorrent_progress:peerhandle(),
    histogram  :: etorrent_histogram:peerhandle(),
    endgame    :: etorrent_endgame:peerhandle()}).

-opaque peerhandle() :: #peerhandle{}.
-type peerhandleupdate() :: {endgame, boolean()}.
-export_type([peerhandle/0]).
-define(endgame(Handle), (Handle#peerhandle.in_endgame)).


%% @doc
%% @end
-spec peerhandle(torrent_id()) -> peerhandle().
peerhandle(TorrentID) ->
    Pending   = etorrent_progress:peerhandle(TorrentID),
    Progress  = etorrent_progress:peerhandle(TorrentID),
    Histogram = etorrent_histogram:peerhandle(TorrentID),
    Endgame   = etorrent_endgame:peerhandle(TorrentID),
    Inendgame = etorrent_endgame:is_active(Endgame),
    Handle = #peerhandle{
        torrent_id=TorrentID,
        in_endgame=Inendgame,
        pending=Pending,
        progress=Progress,
        histogram=Histogram,
        endgame=Endgame},
    Handle.


%% @doc
%% @end
-spec update(peerhandleupdate(), peerhandle()) -> peerhandle().
update({endgame, Inendgame}, Handle) when is_boolean(Inendgame) ->
    Handle#peerhandle{in_endgame=Inendgame}.


%% @doc
%% @end
-spec request_chunks(non_neg_integer(), pieceset(), peerhandle()) ->
    {ok, assigned | not_interested | [chunkspec()]}.
request_chunks(Numchunks, Peerset, Handle) when ?endgame(Handle) ->
    #peerhandle{endgame=Endgame} = Handle,
    etorrent_endgame:request_chunks(Numchunks, Peerset, Endgame);

request_chunks(Numchunks, Peerset, Handle) ->
    #peerhandle{progress=Progress, endgame=Endgame} = Handle,
    case etorrent_progress:request_chunks(Numchunks, Peerset, Progress) of
        {error, endgame} ->
            etorrent_endgame:request_chunks(Numchunks, Peerset, Endgame);
        Other -> Other
    end.


%% @doc
%% @end
-spec mark_dropped(pieceindex(), chunkoffset(), chunklength(), peerhandle()) -> ok.
mark_dropped(Piece, Offset, Length, Handle) when ?endgame(Handle) ->
    #peerhandle{pending=Pending, endgame=Endgame} = Handle,
    ok = etorrent_endgame:mark_dropped(Piece, Offset, Length, Endgame),
    ok = etorrent_pending:mark_dropped(Piece, Offset, Length, Pending);

mark_dropped(Piece, Offset, Length, Handle) ->
    #peerhandle{pending=Pending, progress=Progress, endgame=Endgame} = Handle,
    case etorrent_progress:mark_dropped(Piece, Offset, Length, Progress) of
        {error, endgame} ->
            ok = etorrent_endgame:mark_dropped(Piece, Offset, Length, Endgame),
            ok = etorrent_pending:mark_dropped(Piece, Offset, Length, Pending);
        ok ->
            ok = etorrent_pending:mark_dropped(Piece, Offset, Length, Pending)
    end.


%% @doc
%% @end
-spec mark_fetched(pieceindex(), chunkoffset(), chunklength(), peerhandle()) -> ok.
mark_fetched(Piece, Offset, Length, Handle) when ?endgame(Handle) ->
    #peerhandle{endgame=Endgame} = Handle,
    ok = etorrent_endgame:mark_fetched(Piece, Offset, Length, Endgame);

mark_fetched(_, _, _, _) ->
    ok.


%% @doc
%% @end
-spec mark_stored(pieceindex(), chunkoffset(), chunklength(), peerhandle()) -> ok.
mark_stored(Piece, Offset, Length, Handle) ->
   #peerhandle{pending=Pending, progress=Progress, endgame=Endgame} = Handle,
    ok = etorrent_progress:mark_stored(Piece, Offset, Length, Progress),
    ok = etorrent_pending:mark_stored(Piece, Offset, Length, Pending).
