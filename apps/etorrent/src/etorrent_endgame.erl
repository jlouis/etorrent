-module(etorrent_endgame).
-behaviour(gen_server).

%% exported functions
-export([start_link/1,
         is_active/1,
         activate/1]).

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
    pending  :: pid(),
    requests :: gb_tree(),
    fetched  :: gb_tree(),
    stored   :: gb_tree()}).


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
-spec is_active(pid()) -> boolean().
is_active(SrvPid) ->
    gen_server:call(SrvPid, is_active).


%% @doc
%% @end
-spec activate(pid()) -> ok.
activate(SrvPid) ->
    gen_server:call(SrvPid, activate).


%% @private
init([TorrentID]) ->
    true = register_server(TorrentID),
    Pending = etorrent_pending:await_server(TorrentID),
    InitState = #state{
        active=false,
        pending=Pending,
        requests=gb_trees:empty(),
        fetched=gb_trees:empty(),
        stored=gb_sets:empty()},
    {ok, InitState}.


%% @private
handle_call(is_active, _, State) ->
    #state{active=IsActive} = State,
    {reply, IsActive, State};

handle_call(activate, _, State) ->
    #state{active=false} = State,
    NewState = State#state{active=true},
    {reply, ok, NewState};

handle_call({chunk, {request, _, Peerset, Pid}}, _, State) ->
    #state{pending=Pending, requests=Requests} = State,
    Request = etorrent_utils:find(
        fun({{Index, _, _}, Peers}) ->
            (etorrent_pieceset:is_member(Index, Peerset))
            andalso (not lists:member(Pid, Peers))
        end, gb_trees:to_list(Requests)),
    case Request of
        false ->
            {reply, {ok, assigned}, State};
        {{Index, Offset, Length}=Chunk, Peers} ->
            etorrent_chunkstate:assigned(Index, Offset, Length, Pid, Pending),
            NewRequests = gb_trees:update(Chunk, [Pid|Peers], Requests),
            NewState = State#state{requests=NewRequests},
            {reply, {ok, [Chunk]}, NewState}
    end.


%% @private
handle_cast(_, State) ->
    {stop, not_handled, State}.


%% @private
handle_info({chunk, {assigned, Index, Offset, Length, Pid}}, State) ->
    %% Load a request that was assigned by etorrent_progress
    #state{active=true, requests=Requests} = State,
    Chunk = {Index, Offset, Length},
    NewRequests = gb_trees:insert(Chunk, [Pid], Requests),
    NewState = State#state{requests=NewRequests},
    {noreply, NewState};

handle_info({chunk, {dropped, Index, Offset, Length, Pid}}, State) ->
    #state{active=true, requests=Requests, fetched=Fetched} = State,
    Chunk = {Index, Offset, Length},
    {WasFetcher, NewFetched} = case gb_trees:lookup(Chunk, Fetched) of
        none -> {false, Fetched};
        {value, Pid} -> {true, gb_trees:delete(Chunk, Fetched)}
    end,
    NewRequests = case gb_trees:lookup(Chunk, Requests) of
        none when WasFetcher -> gb_trees:insert(Chunk, [], Requests);
        none -> Requests;
        {value, Peers} -> gb_trees:update(Chunk, Peers -- [Pid], Requests)
    end,
    NewState = State#state{requests=NewRequests, fetched=NewFetched},
    {noreply, NewState};

handle_info({chunk, {fetched, Index, Offset, Length, Pid}}, State) ->
    #state{active=true, requests=Requests, fetched=Fetched} = State,
    Chunk = {Index, Offset, Length},
    {NewFetched, NewRequests} = case gb_trees:lookup(Chunk, Requests) of
        none -> {Fetched, Requests};
        {value, Peers} ->
            [etorrent_peer_control:cancel(Peer, Index, Offset, Length) || Peer <- Peers],
            IFetched = gb_trees:insert(Chunk, Pid, Fetched),
            IRequests = gb_trees:delete(Chunk, Requests),
            {IFetched, IRequests}
    end,
    NewState = State#state{requests=NewRequests, fetched=NewFetched},
    {noreply, NewState};

handle_info({chunk, {stored, Index, Offset, Length, Pid}}, State) ->
    #state{active=true,
        requests=Requests,
        fetched=Fetched,
        stored=Stored} = State,
    Chunk = {Index, Offset, Length},
    NewState = case gb_trees:lookup(Chunk, Fetched) of
        none -> State;
        {value, _} -> 
            NewFetched = gb_trees:delete(Chunk, Fetched),
            NewStored = gb_sets:insert(Chunk, Stored),
            INewState = State#state{
                fetched=NewFetched,
                stored=NewStored},
            INewState
    end,
    {noreply, NewState}.

terminate(_, State) ->
    {ok, State}.

code_change(_, State, _) ->
    {ok, State}.


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(endgame, ?MODULE).
-define(pending, etorrent_pending).
-define(chunkstate, etorrent_chunkstate).

testid() -> 0.
testpid() -> ?endgame:lookup_server(testid()).
testset() -> etorrent_pieceset:from_list([0], 8).
pending() -> ?pending:lookup_server(testid()).
mainpid() -> etorrent_utils:lookup(?MODULE).

setup() ->
    etorrent_utils:register(?MODULE),
    {ok, PPid} = ?pending:start_link(testid()),
    {ok, EPid} = ?endgame:start_link(testid()),
    ok = ?pending:receiver(EPid, PPid),
    ok = ?pending:register(PPid),
    {PPid, EPid}.

teardown({PPid, EPid}) ->
    etorrent_utils:unregister(?MODULE),
    ok = etorrent_utils:shutdown(EPid),
    ok = etorrent_utils:shutdown(PPid).



endgame_test_() ->
    {setup, local,
        fun() -> application:start(gproc) end,
        fun(_) -> application:stop(gproc) end,
    {foreach, local,
        fun setup/0,
        fun teardown/1, [
    ?_test(test_registers()),
    ?_test(test_starts_inactive()),
    ?_test(test_activated()),
    ?_test(test_active_one_assigned()),
    ?_test(test_active_one_dropped()),
    ?_test(test_active_one_fetched()),
    ?_test(test_active_one_stored())
    ]}}.

test_registers() ->
    ?assert(is_pid(?endgame:lookup_server(testid()))),
    ?assert(is_pid(?endgame:await_server(testid()))).

test_starts_inactive() ->
    ?assertNot(?endgame:is_active(testpid())).

test_activated() ->
    ?assertEqual(ok, ?endgame:activate(testpid())),
    ?assert(?endgame:is_active(testpid())).

test_active_one_assigned() ->
    ok = ?endgame:activate(testpid()),
    Pid = spawn_link(fun() ->
        ?pending:register(pending()),
        ?chunkstate:assigned(0, 0, 1, self(), testpid()),
        mainpid() ! assigned,
        etorrent_utils:expect(die)
    end),
    etorrent_utils:expect(assigned),
    ?assertEqual({ok, [{0, 0, 1}]}, ?chunkstate:request(1, testset(), testpid())),
    ?assertEqual({ok, assigned}, ?chunkstate:request(1, testset(), testpid())),
    Pid ! die, etorrent_utils:wait(Pid).

test_active_one_dropped() ->
    ok = ?endgame:activate(testpid()),
    Pid = spawn_link(fun() ->
        ?pending:register(pending()),
        ?chunkstate:assigned(0, 0, 1, self(), testpid()),
        ?chunkstate:dropped(0, 0, 1, self(), testpid()),
        mainpid() ! dropped,
        etorrent_utils:expect(die)
    end),
    etorrent_utils:expect(dropped),
    ?assertEqual({ok, [{0, 0, 1}]}, ?chunkstate:request(1, testset(), testpid())),
    Pid ! die, etorrent_utils:wait(Pid).

test_active_one_fetched() ->
    ok = ?endgame:activate(testpid()),
    %% Spawn a separate process to introduce the chunk into endgame
    Orig = spawn_link(fun() ->
        ?pending:register(pending()),
        ?chunkstate:assigned(0, 0, 1, self(), testpid()),
        mainpid() ! assigned,
        etorrent_utils:expect(die)
    end),
    etorrent_utils:expect(assigned),
    %% Spawn a process that aquires the chunk from endgame and marks it as fetched
    Pid = spawn_link(fun() ->
        ?pending:register(pending()),
        {ok, [{0,0,1}]} = ?chunkstate:request(1, testset(), testpid()),
        ?chunkstate:fetched(0, 0, 1, self(), testpid()),
        mainpid() ! fetched,
        etorrent_utils:expect(die)
    end),
    etorrent_utils:expect(fetched),
    %% Expect endgame to not send out requests for the fetched chunk
    ?assertEqual({ok, assigned}, ?chunkstate:request(1, testset(), testpid())),
    Pid ! die, etorrent_utils:wait(Pid),
    etorrent_utils:ping(pending()),
    etorrent_utils:ping(testpid()),
    %% Expect endgame to send out request if the chunk is dropped before it's stored
    ?assertEqual({ok, [{0, 0, 1}]}, ?chunkstate:request(1, testset(), testpid())),
    Orig ! die, etorrent_utils:wait(Orig).

test_active_one_stored() ->
    ok = ?endgame:activate(testpid()),
    %% Spawn a separate process to introduce the chunk into endgame
    Orig = spawn_link(fun() ->
        ?pending:register(pending()),
        ?chunkstate:assigned(0, 0, 1, self(), testpid()),
        mainpid() ! assigned,
        etorrent_utils:expect(die)
    end),
    etorrent_utils:expect(assigned),
    %% Spawn a process that aquires the chunk from endgame and marks it as stored
    Pid = spawn_link(fun() ->
        ?pending:register(pending()),
        {ok, [{0,0,1}]} = ?chunkstate:request(1, testset(), testpid()),
        ?chunkstate:fetched(0, 0, 1, self(), testpid()),
        ?chunkstate:stored(0, 0, 1, self(), testpid()),
        mainpid() ! stored,
        etorrent_utils:expect(die)
    end),
    etorrent_utils:expect(stored),
    ?assertEqual({ok, assigned}, ?chunkstate:request(1, testset(), testpid())),
    Pid ! die, etorrent_utils:wait(Pid),
    etorrent_utils:ping(pending()),
    etorrent_utils:ping(testpid()),
    ?assertEqual({ok, assigned}, ?chunkstate:request(1, testset(), testpid())),
    Orig ! die, etorrent_utils:wait(Orig).




-endif.
