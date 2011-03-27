-module(etorrent_pending).
-behaviour(gen_server).

%% exported functions
-export([start_link/1,
         peerhandle/1,
         originhandle/1,
         start_endgame/1,
         mark_sent/5,
         mark_dropped/4,
         mark_stored/4]).

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


-record(state, {
    endgame  :: pid(),
    receiver :: pid(),
    table :: ets:tid()}).

-opaque peerhandle() :: {peer, pid()}.
-opaque originhandle() :: {origin, pid()}.
-export_type([peerhandle/0, originhandle/0]).

-type torrent_id()  :: etorrent_types:torrent_id().
-type pieceindex()  :: etorrent_types:pieceindex().
-type chunkoffset() :: etorrent_types:chunkoffset().
-type chunklength() :: etorrent_types:chunklength().


register_server(TorrentID) ->
    etorrent_utils:register(server_name(TorrentID)).

lookup_server(TorrentID) ->
    etorrent_utils:lookup(server_name(TorrentID)).

await_server(TorrentID) ->
    etorrent_utils:await(server_name(TorrentID)).

server_name(TorrentID) ->
    {etorrent, TorrentID, pending}.


%% @doc
%% @end
-spec start_link(torrent_id()) -> {ok, pid()}.
start_link(TorrentID) ->
    gen_server:start_link(?MODULE, [TorrentID], []).


%% @doc
%% @end
-spec peerhandle(torrent_id()) -> peerhandle().
peerhandle(TorrentID) ->
    SrvPid = await_server(TorrentID),
    gen_server:call(SrvPid, {register_peer, self()}),
    {peer, SrvPid}.


%% @doc
%% @end
-spec originhandle(torrent_id()) -> originhandle().
originhandle(TorrentID) ->
    SrvPid = await_server(TorrentID),
    {origin, SrvPid}.


%% @doc
%% @end
-spec start_endgame(originhandle()) -> ok.
start_endgame({origin, SrvPid}) ->
    ok = gen_server:call(SrvPid, start_endgame),
    Ref = self() ! make_ref(),
    bounce_dropped(SrvPid, Ref).

bounce_dropped(SrvPid, Ref) ->
    receive
        {dropped, Index, Offset, Length} ->
            mark_dropped_(SrvPid, Index, Offset, Length),
            bounce_dropped(SrvPid, Ref);
        Ref -> ok
    end.


%% @doc
%% @end
-spec mark_sent(pieceindex(), chunkoffset(), chunklength(),
                pid(), originhandle()) -> ok.
mark_sent(Piece, Offset, Length, Pid, {origin, SrvPid}) ->
    gen_server:cast(SrvPid, {mark_sent, Pid, Piece, Offset, Length}).


%% @doc
%% @end
-spec mark_dropped(pieceindex(), chunkoffset(), chunklength(), peerhandle()) -> ok.
mark_dropped(Piece, Offset, Length, {peer, SrvPid}) ->
    mark_dropped_(SrvPid, Piece, Offset, Length).

mark_dropped_(SrvPid, Piece, Offset, Length) ->
    gen_server:cast(SrvPid, {mark_dropped, self(), Piece, Offset, Length}).


%% @doc
%% @end
-spec mark_stored(pieceindex(), chunkoffset, chunklength(), peerhandle()) -> ok.
mark_stored(Piece, Offset, Length, {peer, SrvPid}) ->
    gen_server:cast(SrvPid, {mark_stored, self(), Piece, Offset, Length}).


init([TorrentID]) ->
    true = register_server(TorrentID),
    Progress = etorrent_progress:await_server(TorrentID),
    Endgame = etorrent_endgame:await_server(TorrentID),
    Table = ets:new(none, [private, set]),
    InitState = #state{
        receiver=Progress,
        endgame=Endgame,
        table=Table},
    {ok, InitState}.


handle_call({register_peer, Pid}, _, State) ->
    #state{table=Table} = State,
    Ref = erlang:monitor(process, Pid),
    case ets:insert_new(Table, {Pid, Ref}) of
        true  -> ok;
        false -> erlang:demonitor(Ref)
    end,
    {reply, ok, State};

handle_call(start_endgame, _, State) ->
    #state{endgame=Endgame, table=Table} = State,
    ReqTerm  = {'$1', '$2', '$3', '$4'},
    ReqHead  = {ReqTerm},
    Requests = ets:select(Table, {ReqHead, [], ReqTerm}),
    [etorrent_endgame:mark_sent(I, O, L, P, Endgame) || {I, O, L, P} <- Requests],
    NewState = State#state{receiver=Endgame},
    {reply, ok, NewState}.


handle_cast({mark_sent, Pid, Index, Offset, Length}, State) ->
    #state{receiver=Receiver, table=Table} = State,
    case insert_request(Table, Pid, Index, Offset, Length) of
        false -> notify(Receiver, Index, Offset, Length);
        true  -> ok
    end,
    {noreply, State};

handle_cast({mark_stored, Pid, Piece, Offset, Length}, State) ->
    #state{table=Table} = State,
    delete_request(Table, Pid, Piece, Offset, Length),
    {noreply, State};

handle_cast({mark_dropped, Pid, Piece, Offset, Length}, State) ->
    #state{receiver=Receiver, table=Table} = State,
    notify(Receiver, Piece, Offset, Length),
    delete_request(Table, Pid, Piece, Offset, Length),
    {noreply, State}.


handle_info({'DOWN', _, process, Pid, _}, State) ->
    #state{receiver=Receiver, table=Table} = State,
    Chunks = flush_requests(Table, Pid),
    ok = notify(Receiver, Chunks),
    true = ets:delete(Table, Pid),
    {noreply, State}.

terminate(_, State) ->
    {ok, State}.

code_change(_, State, _) ->
    {ok, State}.


notify(Receiver, Piece, Offset, Length) ->
    Receiver ! {dropped, Piece, Offset, Length},
    ok.

notify(Receiver, Chunks) ->
    [notify(Receiver, I, O, L) || {I, O, L} <- Chunks],
    ok.

delete_request(Table, Pid, Piece, Offset, Length) ->
    case ets:member(Table, Pid) of
        false -> ok;
        true  -> ets:delete(Table, {Pid, Piece, Offset, Length})
    end.

insert_request(Table, Pid, Piece, Offset, Length) ->
    case ets:member(Table, Pid) of
        false -> false;
        true -> ets:insert(Table, {{Pid, Piece, Offset, Length}})
    end.

flush_requests(Table, Pid) ->
    Match = {{Pid, '_', '_', '_'}},
    Rows  = ets:match_object(Table, Match),
    true  = ets:match_delete(Table, Match),
    [{I, O, L} || {_, I, O, L} <- Rows].
    

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(pending, ?MODULE).

-endif.
