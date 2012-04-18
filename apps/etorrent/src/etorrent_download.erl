-module(etorrent_download).


%% exported functions
-export([await_servers/1,
         request_chunks/3,
         chunk_dropped/4,
         chunks_dropped/2,
         chunk_fetched/4,
         chunk_stored/4]).

%% gproc registry entries
-export([register_server/1,
         unregister_server/1,
         lookup_server/1,
         await_server/1]).

%% update functions
-export([switch_assignor/2,
         update/2]).

-type torrent_id()  :: etorrent_types:torrent_id().
-type pieceset()    :: etorrent_pieceset:pieceset().
-type pieceindex()  :: etorrent_types:piece_index().
-type chunk_offset() :: etorrent_types:chunk_offset().
-type chunk_length() :: etorrent_types:chunk_len().
-type chunkspec()   :: {pieceindex(), chunk_offset(), chunk_length()}.
-type update_query() :: {assignor, pid()}.


-record(tservices, {
    torrent_id :: torrent_id(),
    assignor   :: pid(),
    pending    :: pid(),
    histogram  :: pid()}).
-opaque tservices() :: #tservices{}.
-export_type([tservices/0]).


-spec register_server(torrent_id()) -> true.
register_server(TorrentID) ->
    etorrent_utils:register(server_name(TorrentID)).

-spec unregister_server(torrent_id()) -> true.
unregister_server(TorrentID) ->
    etorrent_utils:unregister(server_name(TorrentID)).

-spec lookup_server(torrent_id()) -> pid().
lookup_server(TorrentID) ->
    etorrent_utils:lookup(server_name(TorrentID)).

-spec await_server(torrent_id()) -> pid().
await_server(TorrentID) ->
    etorrent_utils:await(server_name(TorrentID)).

server_name(TorrentID) ->
    {etorrent, TorrentID, assignor}.



%% @doc
%% @end
-spec await_servers(torrent_id()) -> tservices().
await_servers(TorrentID) ->
    Pending   = etorrent_pending:await_server(TorrentID),
    Assignor  = await_server(TorrentID),
    Histogram = etorrent_scarcity:await_server(TorrentID),
    ok = etorrent_pending:register(Pending),
    Handle = #tservices{
        torrent_id=TorrentID,
        pending=Pending,
        assignor=Assignor,
        histogram=Histogram},
    Handle.


%% @doc Run `update/2' for the peer with Pid.
%%      It allows to change the Hangle tuple.
%% @end
-spec switch_assignor(pid(), pid()) -> ok.
switch_assignor(PeerPid, Assignor) ->
    PeerPid ! {download, {assignor, Assignor}},
    ok.


%% @doc This function is called by peer.
%% @end
-spec update(update_query(), tservices()) -> tservices().
update({assignor, Assignor}, Handle) when is_pid(Assignor) ->
    Handle#tservices{assignor=Assignor}.


%% @doc
%% @end
-spec request_chunks(non_neg_integer(), pieceset(), tservices()) ->
    {ok, assigned | not_interested | [chunkspec()]}.
request_chunks(Numchunks, Peerset, Handle) ->
    #tservices{assignor=Assignor} = Handle,
    etorrent_chunkstate:request(Numchunks, Peerset, Assignor).


%% @doc
%% @end
-spec chunk_dropped(pieceindex(),
                    chunk_offset(), chunk_length(), tservices()) -> ok.
chunk_dropped(Piece, Offset, Length, Handle)->
    #tservices{pending=Pending, assignor=Assignor} = Handle,
    ok = etorrent_chunkstate:dropped(Piece, Offset, Length, self(), Assignor),
    ok = etorrent_chunkstate:dropped(Piece, Offset, Length, self(), Pending).


%% @doc
%% @end
-spec chunks_dropped([chunkspec()], tservices()) -> ok.
chunks_dropped(Chunks, Handle) ->
    #tservices{pending=Pending, assignor=Assignor} = Handle,
    ok = etorrent_chunkstate:dropped(Chunks, self(), Assignor),
    ok = etorrent_chunkstate:dropped(Chunks, self(), Pending).


%% @doc
%% @end
-spec chunk_fetched(pieceindex(),
                    chunk_offset(), chunk_length(), tservices()) -> ok.
chunk_fetched(Piece, Offset, Length, Handle) ->
    #tservices{assignor=Assignor} = Handle,
    ok = etorrent_chunkstate:fetched(Piece, Offset, Length, self(), Assignor).


%% @doc
%% @end
-spec chunk_stored(pieceindex(),
                   chunk_offset(), chunk_length(), tservices())
                  -> ok.
chunk_stored(Piece, Offset, Length, Handle) ->
    #tservices{pending=Pending, assignor=Assignor} = Handle,
    ok = etorrent_chunkstate:stored(Piece, Offset, Length, self(), Assignor),
    ok = etorrent_chunkstate:stored(Piece, Offset, Length, self(), Pending).
