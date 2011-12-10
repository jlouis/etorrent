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

-type torrent_id()  :: etorrent_types:torrent_id().
-type pieceindex()  :: etorrent_types:piece_index().
-type chunk_offset() :: etorrent_types:chunk_offset().
-type chunk_length() :: etorrent_types:chunk_len().
-type chunkspec()   :: {pieceindex(), chunk_offset(), chunk_length()}.

-record(state, {
    torrent_id = exit(required) :: torrent_id(),
    active     = exit(required) :: boolean(),
    pending    = exit(required) :: pid(),
    assigned   = exit(required) :: gb_tree(),
    fetched    = exit(required) :: gb_tree(),
    stored     = exit(required) :: gb_set()}).


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
        torrent_id=TorrentID,
        active=false,
        pending=Pending,
        assigned=gb_trees:empty(),
        fetched=gb_trees:empty(),
        stored=gb_sets:empty()},
    {ok, InitState}.


%% @private
handle_call(is_active, _, State) ->
    #state{active=IsActive} = State,
    {reply, IsActive, State};

handle_call(activate, _, State) ->
    #state{active=false, torrent_id=TorrentID} = State,
    lager:info([{endgame, TorrentID}],
               "Endgame active ~w", [TorrentID]),
    NewState = State#state{active=true},
    Peers = etorrent_peer_control:lookup_peers(TorrentID),
    [etorrent_download:activate_endgame(Peer) || Peer <- Peers],
    {reply, ok, NewState};

handle_call({chunk, {request, _, Peerset, Pid}}, _, State) ->
    #state{
        active=true,
        pending=Pending,
        assigned=Assigned} = State,
    Request = etorrent_utils:find(
        fun({Index, _, _}=Chunk) ->
            etorrent_pieceset:is_member(Index, Peerset)
            andalso not has_assigned(Chunk, Pid, Assigned)
        end, get_assigned(Assigned)),
    case Request of
        false ->
            {reply, {ok, assigned}, State};
        {Index, Offset, Length}=Chunk ->
            etorrent_chunkstate:assigned(Index, Offset, Length, Pid, Pending),
            NewAssigned = add_assigned(Chunk, Pid, Assigned),
            NewState = State#state{assigned=NewAssigned},
            {reply, {ok, [Chunk]}, NewState}
    end;

handle_call({chunk, requests}, _, State) ->
    #state{assigned=Assigned, fetched=Fetched} = State,
    AllReqs = gb_trees:to_list(Assigned) ++ gb_trees:to_list(Fetched),
    Reply = [{Pid, Chunk} || {Chunk, Pids} <- AllReqs, Pid <- Pids],
    {reply, Reply, State}.


%% @private
handle_cast(_, State) ->
    {stop, not_handled, State}.


%% @private
handle_info({chunk, {assigned, Index, Offset, Length, Pid}}, State) ->
    %% Load a request that was assigned by etorrent_progress
    #state{assigned=Assigned} = State,
    Chunk = {Index, Offset, Length},
    NewAssigned = add_assigned(Chunk, Pid, Assigned),
    NewState = State#state{assigned=NewAssigned},
    {noreply, NewState};

handle_info({chunk, {dropped, Index, Offset, Length, Pid}}, State) ->
    #state{
        assigned=Assigned,
        fetched=Fetched,
        stored=Stored} = State,
    Chunk = {Index, Offset, Length},
    Isstored = is_stored(Chunk, Stored),
    Isfetched = Isstored orelse is_fetched(Chunk, Fetched),
    Wasfetched = Isfetched orelse has_fetched(Chunk, Pid, Fetched),
    NewState = if
        Isstored ->
            State;
        Isfetched and Wasfetched ->
            NewFetched = del_fetched(Chunk, Pid, Fetched),
            Stillfetched = is_fetched(Chunk, NewFetched),
            if  Stillfetched ->
                    State#state{fetched=NewFetched};
                not Stillfetched  ->
                    NewAssigned = add_assigned(Chunk, Assigned),
                    State#state{assigned=NewAssigned, fetched=NewFetched}
            end;
        Isfetched ->
            State;
        true ->
            NewAssigned = del_assigned(Chunk, Pid, Assigned),
            State#state{assigned=NewAssigned}
    end,
    {noreply, NewState};

handle_info({chunk, {fetched, Index, Offset, Length, Pid}}, State) ->
    #state{
        active=true,
        assigned=Assigned,
        fetched=Fetched,
        stored=Stored} = State,
    Chunk = {Index, Offset, Length},
    Isstored = is_stored(Chunk, Stored),
    Isfetched = Isstored orelse is_fetched(Chunk, Fetched),
    Notify = fun(Peer) ->
        etorrent_chunkstate:fetched(Index, Offset, Length, Pid, Peer)
    end,
    NewState = if
        Isstored ->
            State;
        Isfetched ->
            NewFetched = add_fetched(Chunk, Pid, Fetched),
            State#state{fetched=NewFetched};
        not Isfetched ->
            NewFetched = add_fetched(Chunk, Pid, Fetched),
            NewAssigned = del_assigned(Chunk, Assigned),
            [Notify(Peer) || Peer <- get_assigned(Chunk, Assigned)],
            State#state{ assigned=NewAssigned, fetched=NewFetched}
    end,
    {noreply, NewState};

handle_info({chunk, {stored, Index, Offset, Length, Pid}}, State) ->
    #state{
        active=true,
        fetched=Fetched,
        stored=Stored} = State,
    Chunk = {Index, Offset, Length},
    case has_fetched(Chunk, Pid, Fetched) of
        false ->
            {noreply, State};
        true ->
            NewState = State#state{
                fetched=del_fetched(Chunk, Pid, Fetched),
                stored=add_stored(Chunk, Stored)},
            {noreply, NewState}
    end.

terminate(_, State) ->
    {ok, State}.

code_change(_, State, _) ->
    {ok, State}.


%% @doc Get the list of all assigned chunks
-spec get_assigned(gb_tree()) -> [chunkspec()].
get_assigned(Assigned) ->
    gb_trees:keys(Assigned).

%% @doc Get the list of peers that has been assigned a chunk
-spec get_assigned(chunkspec(), gb_tree()) -> [pid()].
get_assigned(Chunk, Assigned) ->
    gb_trees:get(Chunk, Assigned).

%% @doc Check if a peer has been assigned a chunk
-spec has_assigned(chunkspec(), pid(), gb_tree()) -> boolean().
has_assigned(Chunk, Pid, Assigned) ->
    has_peer(Chunk, Pid, Assigned).

-spec add_assigned(chunkspec(), gb_tree()) -> gb_tree().
add_assigned(Chunk, Assigned) ->
    gb_trees:insert(Chunk, [], Assigned).

%% @doc Append a peer to the list of peers that has been assigned a chunk
-spec add_assigned(chunkspec(), pid(), gb_tree()) -> gb_tree().
add_assigned(Chunk, Pid, Assigned) ->
    add_peer(Chunk, Pid, Assigned).

%% @doc Delete a peer from the list of peers that has been assigned a chunk
-spec del_assigned(chunkspec(), pid(), gb_tree()) -> gb_tree().
del_assigned(Chunk, Pid, Assigned) ->
    del_peer(Chunk, Pid, Assigned).

%% @doc Delete all peers from the list of peers that has been assigned a chunk
-spec del_assigned(chunkspec(), gb_tree()) -> gb_tree().
del_assigned(Chunk, Assigned) ->
    gb_trees:delete(Chunk, Assigned).

%% @doc Append a peer to the list of peers that has fetched a chunk
-spec add_fetched(chunkspec(), pid(), gb_tree()) -> gb_tree().
add_fetched(Chunk, Pid, Fetched) ->
    add_peer(Chunk, Pid, Fetched).

%% @doc Delete a peer from the list of peers that has fetched a chunk
-spec del_fetched(chunkspec(), pid(), gb_tree()) -> gb_tree().
del_fetched(Chunk, Pid, Fetched) ->
    del_peer(Chunk, Pid, Fetched).

%% @doc Check if a chunk is a member of the set of fetched chunks
-spec is_fetched(chunkspec(), gb_tree()) -> boolean().
is_fetched(Chunk, Fetched) ->
    gb_trees:is_defined(Chunk, Fetched)
    andalso length(gb_trees:get(Chunk, Fetched)) > 0.

%% @doc Check if a peer has fetched a chunk
-spec has_fetched(chunkspec(), pid(), gb_tree()) -> boolean().
has_fetched(Chunk, Pid, Fetched) ->
    has_peer(Chunk, Pid, Fetched).


%% @doc Add a chunk to the set of stored chunks
-spec add_stored(chunkspec(), gb_set()) -> gb_set().
add_stored(Chunk, Stored) ->
    gb_sets:insert(Chunk, Stored).

%% @doc Check if a chunk is a member of the set of stored chunks
-spec is_stored(chunkspec(), gb_set()) -> boolean().
is_stored(Chunk, Stored) ->
    gb_sets:is_member(Chunk, Stored).

%% @doc Add a peer to a set of peers that are associated with a chunk
-spec add_peer(chunkspec(), pid(), gb_tree()) -> gb_tree().
add_peer(Chunk, Pid, Requests) ->
    case gb_trees:lookup(Chunk, Requests) of
        none ->
            gb_trees:insert(Chunk, [Pid], Requests);
        {value, Pids} ->
            %% Assert that a peer only fetches a chunk once
            not lists:member(Pid, Pids) orelse error(badarg),
            gb_trees:update(Chunk, [Pid|Pids], Requests)
    end.

%% @doc Delete a peer from a set of peers associated with a chunk
-spec del_peer(chunkspec(), pid(), gb_tree()) -> gb_tree().
del_peer(Chunk, Pid, Requests) ->
    case gb_trees:lookup(Chunk, Requests) of
        none ->
            Requests;
        {value, Pids} ->
            NewPids = Pids -- [Pid],
            gb_trees:update(Chunk, NewPids, Requests)
    end.

%% @doc Check if a peer is a member of the set of peers associated with a chunk
-spec has_peer(chunkspec(), pid(), gb_tree()) -> boolean().
has_peer(Chunk, Pid, Requests) ->
    gb_trees:is_defined(Chunk, Requests)
    andalso lists:member(Pid, gb_trees:get(Chunk, Requests)).


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
    ?_test(test_active_one_stored()),
    ?_test(test_request_list())
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
    Fetch = fun() -> spawn_link(fun() ->
        ?pending:register(pending()),
        {ok, [{0,0,1}]} = ?chunkstate:request(1, testset(), testpid()),
        ?chunkstate:fetched(0, 0, 1, self(), testpid()),
        mainpid() ! fetched,
        etorrent_utils:expect(die)
    end) end,
    Pid0 = Fetch(),
    Pid1 = Fetch(),
    etorrent_utils:expect(fetched),
    %% Expect endgame to not send out requests for the fetched chunk
    ?assertEqual({ok, assigned}, ?chunkstate:request(1, testset(), testpid())),
    Pid0 ! die, etorrent_utils:wait(Pid0),
    etorrent_utils:ping([pending(), testpid()]),
    ?assertEqual({ok, assigned}, ?chunkstate:request(1, testset(), testpid())),
    %% Expect endgame to not send out requests if two peers have fetched the request
    ?assertEqual({ok, assigned}, ?chunkstate:request(1, testset(), testpid())),
    Pid1 ! die, etorrent_utils:wait(Pid1),
    etorrent_utils:ping([pending(), testpid()]),
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
    etorrent_utils:ping([pending(), testpid()]),
    ?assertEqual({ok, assigned}, ?chunkstate:request(1, testset(), testpid())),
    Orig ! die, etorrent_utils:wait(Orig).

test_request_list() ->
    ok = ?endgame:activate(testpid()),
    Pid = spawn_link(fun() ->
        ?pending:register(pending()),
        ?chunkstate:assigned(0, 0, 1, self(), testpid()),
        ?chunkstate:assigned(0, 1, 1, self(), testpid()),
        ?chunkstate:fetched(0, 1, 1, self(), testpid()),
        mainpid() ! assigned,
        etorrent_utils:expect(die)
    end),
    etorrent_utils:expect(assigned),
    Requests = ?chunkstate:requests(testpid()),
    Pid ! die, etorrent_utils:wait(Pid),
    ?assertEqual([{Pid,{0,0,1}}, {Pid,{0,1,1}}], lists:sort(Requests)).

-endif.
