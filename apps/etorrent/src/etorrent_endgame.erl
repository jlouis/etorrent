-module(etorrent_endgame).
-behaviour(gen_server).

%% exported functions
-export([start_link/1,
         peerhandle/1,
         originhandle/1,
         is_active/1,
         request_chunks/3,
         mark_sent/5,
         mark_dropped/4,
         mark_fetched/4]).

%% gproc registry entries
-export([register_server/1,
         lookup_server/1,
         await_server/1]).

%% gen_server callbacks
-export([init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3]).

-type pieceset()    :: etorrent_pieceset:pieceset().
-type torrent_id()  :: etorrent_types:torrent_id().
-type pieceindex()  :: etorrent_types:pieceindex().
-type chunkoffset() :: etorrent_types:chunkoffset().
-type chunklength() :: etorrent_types:chunklength().
-type chunkspec()   :: {pieceindex(), chunkoffset(), chunklength()}.

-record(state, {
    active   :: boolean(),
    pending  :: etorrent_pending:originhandle(),
    requests :: gb_tree()}).

-opaque peerhandle() :: {peer, pid()}.
-opaque originhandle() :: {origin, pid()}.
-export_type([peerhandle/0, originhandle/0]).


server_name(TorrentID) ->
    {etorrent, TorrentID, endgame}.


%% @doc
%% @end
-spec register_server(torrent_id()) -> true.
register_server(TorrentID) ->
    etorrent_utils:register(server_name(TorrentID)).

%% @doc
%% @end
-spec lookup_server(torrent_id()) -> pid().
lookup_server(TorrentID) ->
    etorrent_utils:lookup(server_name(TorrentID)).

%% @doc
%% @end
-spec await_server(torrent_id()) -> pid().
await_server(TorrentID) ->
    etorrent_utils:await(server_name(TorrentID)).


%% @doc
%% @end
-spec start_link(torrent_id()) -> {ok, pid()}.
start_link(TorrentID) ->
    gen_server:start_link(?MODULE, [TorrentID], []).

%% @doc
%% @end
-spec peerhandle(torrent_id()) -> peerhandle().
peerhandle(TorrentID) ->
    {peer, await_server(TorrentID)}.


%% @doc
%% @end
-spec originhandle(torrent_id()) -> originhandle().
originhandle(TorrentID) ->
    {origin, await_server(TorrentID)}.


%% @doc
%% @end
-spec is_active(peerhandle()) -> boolean().
is_active(SrvPid) ->
    gen_server:call(SrvPid, is_active).

%% @doc
%% @end
-spec request_chunks(pieceset(), non_neg_integer(), peerhandle()) ->
    {ok, [chunkspec()] | assigned}.
request_chunks(Peerset, Numchunks, {peer, SrvPid}) ->
    gen_server:call(SrvPid, {request_chunks, self(), Peerset, Numchunks}).


%% @doc
%% @end
-spec mark_sent(pieceindex, chunkoffset(), chunklength(),
                pid(), originhandle()) -> ok.
mark_sent(Piece, Offset, Length, Pid, {origin, SrvPid}) ->
    gen_server:cast(SrvPid, {mark_sent, Pid, Piece, Offset, Length}),
    ok.


%% @doc
%% @end
-spec mark_dropped(pieceindex(), chunkoffset(), chunklength(), peerhandle()) -> ok.
mark_dropped(Piece, Offset, Length, {peer, SrvPid}) ->
    SrvPid ! {mark_dropped, self(), Piece, Offset, Length},
    ok.


%% @doc
%% @end
-spec mark_fetched(pieceindex(), chunkoffset(), chunklength(), peerhandle()) -> ok.
mark_fetched(Piece, Offset, Length, {peer, SrvPid}) ->
    SrvPid ! {mark_fetched, self(), Piece, Offset, Length},
    ok.


%% @private
init([TorrentID]) ->
    true = register_server(TorrentID),
    Pending = etorrent_pending:originhandle(TorrentID),
    InitState = #state{
        active=false,
        pending=Pending,
        requests=gb_trees:empty()},
    {ok, InitState}.


%% @private
handle_call(is_active, _, State) ->
    #state{active=IsActive} = State,
    {reply, IsActive, State};

handle_call({request_chunks, Pid, Peerset, _}, _, State) ->
    #state{pending=Pending, requests=Requests} = State,
    Request = etorrent_util:find(
        fun({{Index, _, _}, Peers}) ->
            etorrent_pieceset:is_member(Index, Peerset)
            and not lists:member(Pid, Peers)
        end, gb_trees:to_list(Requests)),
    case Request of
        false ->
            {reply, {ok, assigned}, State};
        {{Index, Offset, Length}=Chunk, Peers} ->
            etorrent_pending:mark_sent(Index, Offset, Length, Pid, Pending),
            NewRequests = gb_trees:update(Chunk, [Pid|Peers], Requests),
            NewState = State#state{requests=NewRequests},
            {reply, {ok, [Chunk]}, NewState}
    end.


%% @private
handle_cast(_, State) ->
    {stop, not_handled, State}.


%% @private
handle_info({mark_dropped, Pid, Index, Offset, Length}, State) ->
    #state{requests=Requests} = State,
    Chunk = {Index, Offset, Length},
    case gb_trees:lookup(Chunk, Requests) of
        none -> {noreply, State};
        {value, Peers} ->
            NewRequests = gb_trees:update(Chunk, Peers -- [Pid], Requests),
            NewState = State#state{requests=NewRequests},
            {noreply, NewState}
    end;

handle_info({mark_fetched, Pid, Index, Offset, Length}, State) ->
    #state{requests=Requests} = State,
    Chunk = {Index, Offset, Length},
    case gb_trees:lookup(Chunk, Requests) of
        none -> {noreply, State};
        {value, Peers} ->
            [etorrent_peer_control:cancel(Peer, Index, Offset, Length) || Peer <- Peers],
            NewRequests = gb_trees:delete(Chunk, Requests),
            NewState = State#state{requests=NewRequests},
            {noreply, NewState}
    end.

terminate(_, State) ->
    {ok, State}.

code_change(_, State, _) ->
    {ok, State}.
