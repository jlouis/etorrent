-module(etorrent_pending).
-behaviour(gen_server).
%% This module implements a server process tracking which open
%% requests have been assigned to each peer process. The process
%% assigning the requests to peers are responsible for keeping
%% the request tracking process updated.
%%
%% #Peers
%% Peer processes are responsible for notifying both the request
%% tracking process and the process that assigned the request
%% when a request is dropped, fetched or stored.
%%
%% When a peer exits the request tracking process must notify the
%% process that is responsible for assigning requests that the
%% request has been dropped.
%%
%% #Changing assigning process
%% When endgame mode is activated the assigning process is replaced
%% with the endgame process. The currently open requests are then sent
%% to the endgame process. Any requests that have been sent to but
%% not received by the assigning process is expected to be forwarded
%% to the endgame process by the previous assigning process.

%% exported functions
-export([start_link/1,
         receiver/2]).

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

-spec receiver(pid(), pid()) -> ok.
receiver(Recvpid, Srvpid) ->
    ok = gen_server:call(Srvpid, {receiver, Recvpid}).


%% @private
init([TorrentID]) ->
    true = register_server(TorrentID),
    Table = ets:new(none, [private, set]),
    InitState = #state{
        receiver=self(),
        table=Table},
    {ok, InitState}.


handle_call({register_peer, Peerpid}, _, State) ->
    #state{table=Table} = State,
    Ref = erlang:monitor(process, Peerpid),
    case insert_peer(Table, Peerpid, Ref) of
        true  -> ok;
        false -> erlang:demonitor(Ref)
    end,
    {reply, ok, State};

handle_call({redirect, Newrecvpid}, _, State) ->
    #state{table=Table} = State,
    Requests = list_requests(Table),
    Assigned = fun({Piece, Offset, Length, Peerpid}) ->
        etorrent_chunkstate:assigned(Piece, Offset, Length, Peerpid, Newrecvpid)
    end,
    [Assigned(Request) || Request <- Requests],
    NewState = State#state{receiver=Newrecvpid},
    {reply, ok, NewState}.


handle_cast(_, State) ->
    {stop, not_implemented, State}.


handle_info({chunk, {assigned, Index, Offset, Length, Peerpid}}, State) ->
    %% Consider that the peer may have exited before the assigning process
    %% received the request and sent us this message. If so, bounce back a
    %% dropped-notification immidiately.
    #state{receiver=Receiver, table=Table} = State,
    case insert_request(Table, Peerpid, Index, Offset, Length) of
        true  -> ok;
        false ->
            etorrent_chunkstate:dropped(Index, Offset, Length, Peerpid, Receiver)
    end,
    {noreply, State};

handle_info({chunk, {stored, Piece, Offset, Length, Peerpid}}, State) ->
    #state{table=Table} = State,
    delete_request(Table, Piece, Offset, Length, Peerpid),
    {noreply, State};

handle_info({chunk, {dropped, Piece, Offset, Length, Peerpid}}, State) ->
    %% The peer is expected to send a dropped notification to the
    %% assigning process before notifying this process.
    #state{receiver=Receiver, table=Table} = State,
    delete_request(Table, Piece, Offset, Length, Peerpid),
    {noreply, State};

handle_info({chunk, {dropped, Peerpid}}, State) ->
    %% The same expectations apply as for the previous clause.
    #state{receiver=Receiver, table=Table} = State,
    flush_requests(Table, Peerpid),
    {noreply, State};


handle_info({'DOWN', _, process, Peerpid, _}, State) ->
    #state{receiver=Receiver, table=Table} = State,
    Chunks = flush_requests(Table, Peerpid),
    ok = etorrent_chunkstate:dropped(Chunks, Peerpid, Receiver),
    ok = delete_peer(Table, Peerpid),
    {noreply, State}.

terminate(_, State) ->
    {ok, State}.

code_change(_, State, _) ->
    {ok, State}.

%% The ets table contains two types of records:
%% - {pid(), reference()}
%% - {integer(), integer(), integer(), pid()}

insert_peer(Table, Peerpid, Ref) ->
    Row = {Peerpid, Ref},
    ets:insert_new(Table, Row).

delete_peer(Table, Peerpid) ->
    ets:delete(Table, Peerpid).

insert_request(Table, Piece, Offset, Length, Pid) ->
    Row = {{Piece, Offset, Length, Pid}},
    case ets:member(Table, Pid) of
        false -> false;
        true -> ets:insert(Table, Row)
    end.

delete_request(Table, Piece, Offset, Length, Pid) ->
    Key = {Piece, Offset, Length, Pid},
    case ets:member(Table, Pid) of
        false -> ok;
        true  -> ets:delete(Table, Key)
    end.

flush_requests(Table, Pid) ->
    Match = {{'_', '_', '_', Pid}},
    Rows  = ets:match_object(Table, Match),
    true  = ets:match_delete(Table, Match),
    [{I, O, L} || {_, I, O, L} <- Rows].

list_requests(Table) ->
    ReqHead = {{'$1', '$2', '$3', '$4'}},
    ReqTerm =  {'$1', '$2', '$3', '$4'},
    ets:select(Table, [{ReqHead, [], [ReqTerm]}]).


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(pending, ?MODULE).

-endif.
