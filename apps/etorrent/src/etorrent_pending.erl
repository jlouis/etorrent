-module(etorrent_pending).
-behaviour(gen_server).
-include_lib("stdlib/include/ms_transform.hrl").
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
         register/1,
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
-spec register(pid()) -> ok.
register(Srvpid) ->
    gen_server:call(Srvpid, {register, self()}).


%% @doc
%% @end
-spec receiver(pid(), pid()) -> ok.
receiver(Recvpid, Srvpid) ->
    gen_server:call(Srvpid, {receiver, Recvpid}).


%% @private
init([TorrentID]) ->
    true = register_server(TorrentID),
    Table = ets:new(none, [private, set, {keypos, 1}]),
    InitState = #state{
        receiver=self(),
        table=Table},
    {ok, InitState}.


handle_call({register, Peerpid}, _, State) ->
    #state{table=Table} = State,
    Ref = erlang:monitor(process, Peerpid),
    Reply = case insert_peer(Table, Peerpid, Ref) of
        true  -> ok;
        false ->
            erlang:demonitor(Ref),
            error
    end,
    {reply, Reply, State};

handle_call({receiver, Newrecvpid}, _, State) ->
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
    case insert_request(Table, Index, Offset, Length, Peerpid) of
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
    #state{table=Table} = State,
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
    true = ets:delete(Table, Peerpid),
    ok.

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
    Select = ets:fun2ms(fun({{I, O, L, P}}) when P == Pid -> {I, O, L} end),
    Delete = ets:fun2ms(fun({{_, _, _, P}}) -> P == Pid end),
    Requests  = ets:select(Table, Select),
    ets:select_delete(Table, Delete),
    Requests.

list_requests(Table) ->
    Match = ets:fun2ms(fun({{I, O, L, P}}) -> {I, O, L, P} end),
    ets:select(Table, Match).


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(pending, ?MODULE).
-define(chunks, etorrent_chunkstate).
-define(expect, etorrent_utils:expect).
-define(wait, etorrent_utils:wait).
-define(ping, etorrent_utils:ping).
-define(first, etorrent_utils:first).


testid() -> 0.
testpid() -> ?pending:await_server(testid()).

setup_env() ->
    {ok, Pid} = ?pending:start_link(testid()),
    ok = ?pending:receiver(self(), Pid),
    put({pending, testid()}, Pid),
    Pid.

teardown_env(Pid) ->
    erase({pending, testid()}),
    ok = etorrent_utils:shutdown(Pid).

pending_test_() ->
    {setup, local,
        fun() -> application:start(gproc) end,
        fun(_) -> application:stop(gproc) end,
    {inorder,
    {foreach, local,
        fun setup_env/0,
        fun teardown_env/1,
    [?_test(test_registers()),
     ?_test(test_register_peer()),
     ?_test(test_register_twice()),
     ?_test(test_assigned_dropped()),
     ?_test(test_stored_not_dropped()),
     ?_test(test_dropped_not_dropped()),
     ?_test(test_drop_all_for_pid()),
     ?_test(test_change_receiver()),
     ?_test(test_drop_on_down())
    ]}}}.

test_registers() ->
    ?assert(is_pid(?pending:await_server(testid()))),
    ?assert(is_pid(?pending:lookup_server(testid()))).

test_register_peer() ->
    ?assertEqual(ok, ?pending:register(testpid())).

test_register_twice() ->
    ?assertEqual(ok, ?pending:register(testpid())),
    ?assertEqual(error, ?pending:register(testpid())).

test_assigned_dropped() ->
    Main = self(),
    Pid = spawn_link(fun() ->
        ok = ?pending:register(testpid()),
        Main ! assign,
        ?expect(die)
    end),
    ?expect(assign),
    ?chunks:assigned(0, 0, 1, Pid, testpid()),
    ?chunks:assigned(0, 1, 1, Pid, testpid()),
    Pid ! die,
    ?wait(Pid),
    ?expect({chunk, {dropped, 0, 0, 1, Pid}}),
    ?expect({chunk, {dropped, 0, 1, 1, Pid}}).

test_stored_not_dropped() ->
    Main = self(),
    Pid = spawn_link(fun() ->
        ok = ?pending:register(testpid()),
        Main ! assign,
        ?expect(store),
        ?chunks:stored(0, 0, 1, self(), testpid()),
        Main ! stored,
        ?expect(die)
    end),
    ?expect(assign),
    ?chunks:assigned(0, 0, 1, Pid, testpid()),
    ?chunks:assigned(0, 1, 1, Pid, testpid()),
    Pid ! store,
    ?expect(stored),
    Pid ! die,
    ?wait(Pid),
    ?expect({chunk, {dropped, 0, 1, 1, Pid}}).

test_dropped_not_dropped() ->
    Main = self(),
    Pid = spawn_link(fun() ->
        ok = ?pending:register(testpid()),
        Main ! assign,
        ?expect(drop),
        ?chunks:dropped(0, 0, 1, self(), testpid()),
        Main ! dropped,
        ?expect(die)
    end),
    ?expect(assign),
    ?chunks:assigned(0, 0, 1, Pid, testpid()),
    ?chunks:assigned(0, 1, 1, Pid, testpid()),
    Pid ! drop,
    ?expect(dropped),
    Pid ! die,
    ?wait(Pid),
    ?expect({chunk, {dropped, 0, 1, 1, Pid}}).

test_drop_all_for_pid() ->
    Main = self(),
    Pid = spawn_link(fun() ->
        ok = ?pending:register(testpid()),
        Main ! assign,
        ?expect(drop),
        ?chunks:dropped(self(), testpid()),
        Main ! dropped,
        ?expect(die)
    end),
    ?expect(assign),
    ?chunks:assigned(0, 0, 1, Pid, testpid()),
    ?chunks:assigned(0, 1, 1, Pid, testpid()),
    Pid ! drop, ?expect(dropped),
    Pid ! die, ?wait(Pid),
    self() ! none,
    ?assertEqual(none, ?first()).

test_change_receiver() ->
    Main = self(),
    Pid = spawn_link(fun() ->
        ?pending:receiver(self(), testpid()),
        {peer, Peer} = ?first(),
        ?chunks:assigned(0, 0, 1, Peer, testpid()),
        ?chunks:assigned(0, 1, 1, Peer, testpid()),
        ?pending:receiver(Main, testpid()),
        ?expect(die)
    end),
    Peer = spawn_link(fun() ->
        ?pending:register(testpid()),
        Pid ! {peer, self()},
        ?expect(die)
    end),
    ?expect({chunk, {assigned, 0, 0, 1, Peer}}),
    ?expect({chunk, {assigned, 0, 1, 1, Peer}}),
    Pid ! die,  ?wait(Pid),
    Peer ! die, ?wait(Peer).

test_drop_on_down() ->
    Peer = spawn_link(fun() -> ?pending:register(testpid()) end),
    ?wait(Peer),
    ?chunks:assigned(0, 0, 1, Peer, testpid()),
    ?expect({chunk, {dropped, 0, 0, 1, Peer}}).

-endif.
