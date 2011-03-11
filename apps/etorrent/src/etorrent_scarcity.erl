-module(etorrent_scarcity).
-behaviour(gen_server).
%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc A server to track how many peers provide each piece
%%
%% The scarcity server associates a counter with each piece. When
%% a peer comes online it registers it's prescence to the scarcity
%% server. After the peer has registered it's precence it is responsible
%% for keeping the scarcity server updated with additions to the
%% set of pieces that it's providing, the peer is also expected to
%% provide a copy of the updated piece set to the server.
%%
%% The server is expected to increment the counter and reprioritize
%% the set of pieces of a torrent when the scarcity changes. When a
%% peer exits the server is responsible for decrementing the counter
%% for each piece that was provided by the peerl.
%%
%% The purpose of the server is not to provide a mapping between
%% peers and pieces to other processes.
%%
%% %% # Change notifications
%% A client can subscribe to changes in the ordering of a set of pieces.
%% This is an asynchronous version of get_order/2 with additions to provide
%% continious updates, versioning and context.
%%
%% The client must provide the server with the set of pieces to monitor,
%% a client defined tag for the subscription. The server will provide the
%% client with a unique reference to the subscription.
%%
%% The server should provide the client with the ordering of the pieces
%% at the time of the call. This ensures that the client does not have
%% to retrieve it after the subscription has been established.
%%
%% The server will send an updated order to the client each time the order
%% changes, the client defined tag and the subscription reference is
%% included in each update.
%%
%% The client is expected to cancel and resubscribe if the set of pieces
%% changes. The client is also expected to handle updates that are tagged
%% with an expired subcription reference. The server is expected to cancel
%% subscriptions when a client crashes.
%%
%% ## notes on implementation
%% A complete piece set is provided on each update in order to reduce
%% the amount of effort spent on keeping the two sets synced. This also
%% reduces memory usage for torrents with more than 512 pieces due to
%% the way piece sets are implemented (2011-03-09).
%% @end


%% gproc entries
-export([register_scarcity_server/1,
         lookup_scarcity_server/1,
         await_scarcity_server/1]).

%% api functions
-export([start_link/1,
         add_peer/2,
         add_piece/3,
         get_order/2,
         watch_pieces/3]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).


-type torrent_id() :: etorrent_types:torrent_id().
-type pieceset() :: etorrent_pieceset:pieceset().
-type monitorset() :: etorrent_monitorset:monitorset().

-record(watcher, {
    pid :: pid(),
    ref :: reference(),
    tag :: term(),
    pieceset :: pieceset()}).

-record(state, {
    torrent_id :: torrent_id(),
    num_peers  :: array(),
    peer_monitors :: monitorset(),
    watchers :: [#watcher{}]}).


%% @doc Register as the scarcity server for a torrent
%% @end
-spec register_scarcity_server(torrent_id()) -> true.
register_scarcity_server(TorrentID) ->
    gproc:add_local_name({etorrent, TorrentID, scarcity}).


%% @doc Lookup the scarcity server for a torrent
%% @end
-spec lookup_scarcity_server(torrent_id()) -> pid().
lookup_scarcity_server(TorrentID) ->
    gproc:lookup_local_name({etorrent, TorrentID, scarcity}).


%% @doc Wait for the scarcity server of a torrent to register
%% @end
-spec await_scarcity_server(torrent_id()) -> pid().
await_scarcity_server(TorrentID) ->
    Name = {etorrent, TorrentID, scarcity},
    {Pid, undefined} = gproc:await({n, l, Name}, 5000),
    Pid.


%% @doc Start a scarcity server
%% The server will always register itself as the scarcity
%% server for the given torrent as soon as it has started.
%% @end
-spec start_link(torrent_id()) -> {ok, pid()}.
start_link(TorrentID) ->
    gen_server:start_link(?MODULE, [TorrentID], []).


%% @doc Register as a peer
%% Calling this function will register the current process
%% as a peer under the given torrent. The peer must provide
%% an initial set of pieces to the server in order to relieve
%% the server from handling peers crashing before providing one.
%% @end
-spec add_peer(torrent_id(), pieceset()) -> ok.
add_peer(TorrentID, Pieceset) ->
    SrvPid = lookup_scarcity_server(TorrentID),
    gen_server:call(SrvPid, {add_peer, self(), Pieceset}).


%% @doc Add this peer as the provider of a piece
%% Add this peer as the provider of a piece and send an updated
%% version of the piece set to the server.
%% @end
-spec add_piece(torrent_id(), pos_integer(), pieceset()) -> ok.
add_piece(TorrentID, Index, Pieceset) ->
    SrvPid = lookup_scarcity_server(TorrentID),
    gen_server:call(SrvPid, {add_piece, self(), Index, Pieceset}).


%% @doc Get a list of pieces ordered by scarcity
%% The returned list will only contain pieces that are also members
%% of the piece set. If two pieces are equally scarce the piece index
%% is used to rank the pieces.
%% @end
-spec get_order(torrent_id(), pieceset()) -> {ok, [pos_integer()]}.
get_order(TorrentID, Pieceset) ->
    SrvPid = lookup_scarcity_server(TorrentID),
    gen_server:call(SrvPid, {get_order, Pieceset}).

%% @doc Receive updates to changes in scarcity
%% 
%% @end
-spec watch_pieces(torrent_id(), term(), pieceset()) ->
    {ok, reference(), [pos_integer()]}.
watch_pieces(TorrentID, Tag, Pieceset) ->
    SrvPid = lookup_scarcity_server(TorrentID),
    gen_server:call(SrvPid, {watch, self(), Tag, Pieceset}).


%% @private
init([TorrentID]) ->
    register_scarcity_server(TorrentID),
    InitState = #state{
        torrent_id=TorrentID,
        num_peers=array:new([{default, 0}]),
        peer_monitors=etorrent_monitorset:new(),
        watchers=[]},
    {ok, InitState}.


%% @private
handle_call({add_peer, PeerPid, Pieceset}, _, State) ->
    #state{
        peer_monitors=Monitors,
        num_peers=Numpeers,
        watchers=Watchers} = State,
    NewNumpeers = increment(Pieceset, Numpeers),
    NewMonitors = etorrent_monitorset:insert(PeerPid, Pieceset, Monitors),
    send_updates(Pieceset, Watchers, NewNumpeers),
    NewState = State#state{
        peer_monitors=NewMonitors,
        num_peers=NewNumpeers},
    {reply, ok, NewState};

handle_call({add_piece, Pid, PieceIndex, Pieceset}, _, State) ->
    #state{
        peer_monitors=Monitors,
        num_peers=Numpeers,
        watchers=Watchers} = State,
    Prev = array:get(PieceIndex, Numpeers),
    NewNumpeers = array:set(PieceIndex, Prev + 1, Numpeers),
    NewMonitors = etorrent_monitorset:update(Pid, Pieceset, Monitors),
    send_updates(PieceIndex, Watchers, NewNumpeers),
    NewState = State#state{
        peer_monitors=NewMonitors,
        num_peers=NewNumpeers},
    {reply, ok, NewState};

handle_call({get_order, Pieceset}, _, State) ->
    #state{num_peers=Numpeers} = State,
    Piecelist = sorted_piecelist(Pieceset, Numpeers),
    {reply, {ok, Piecelist}, State};

handle_call({watch, Pid, Tag, Pieceset}, _, State) ->
    #state{
        num_peers=Numpeers,
        watchers=Watchers} = State,
    %% Use a monitor reference as the subscription reference,
    %% this let's us tear down subscriptions when client processes
    %% crash. Currently the interface of the monitorset module does
    %% not let us associate values with monitor references so there
    %% is no benefit to using it in this case.
    Ref = monitor(process, Pid),
    Watcher = #watcher{
        pid=Pid,
        ref=Ref,
        tag=Tag,
        pieceset=Pieceset},
    NewWatchers = [Watcher|Watchers],
    Piecelist = sorted_piecelist(Pieceset, Numpeers),
    NewState = State#state{
        watchers=NewWatchers},
    {reply, {ok, Ref, Piecelist}, NewState}.


%% @private
handle_cast(_, State) ->
    {noreply, State}.


%% @private
handle_info({'DOWN', Ref, process, Pid, _}, State) ->
    #state{
        peer_monitors=Monitors,
        num_peers=Numpeers,
        watchers=Watchers} = State,
    %% We are monitoring two types of clients, peers and
    %% subscribers. If a peer exits we want to update the counters
    %% and notify the subscribers. If a subscriber exits we want
    %% to tear down the subscription. Assume that all monitors
    %% that are not peer monitors are active subscription references.
    NewState = case etorrent_monitorset:is_member(Pid, Monitors) of
        true ->
            Pieceset = etorrent_monitorset:fetch(Pid, Monitors),
            NewNumpeers = decrement(Pieceset, Numpeers),
            NewMonitors = etorrent_monitorset:delete(Pid, Monitors),
            send_updates(Pieceset, Watchers, NewNumpeers),
            INewState = State#state{
                peer_monitors=NewMonitors,
                num_peers=NewNumpeers},
            INewState;
        false ->
            NewWatchers = lists:keydelete(Ref, #watcher.ref, Watchers),
            State#state{watchers=NewWatchers}
    end,
    {noreply, NewState}.


%% @private
terminate(_, State) ->
    {ok, State}.


%% @private
code_change(_, State, _) ->
    {ok, State}.


-spec sorted_piecelist(pieceset(), array()) -> [pos_integer()].
sorted_piecelist(Pieceset, Numpeers) ->
    Piecelist = etorrent_pieceset:to_list(Pieceset),
    lists:sort(fun(A, B) ->
        array:get(A, Numpeers) =< array:get(B, Numpeers)
    end, Piecelist).


-spec decrement(pieceset(), array()) -> array().
decrement(Pieceset, Numpeers) ->
    Piecelist = etorrent_pieceset:to_list(Pieceset),
    lists:foldl(fun(Index, Acc) ->
        PrevCount = array:get(Index, Acc),
        array:set(Index, PrevCount - 1, Acc)
    end, Numpeers, Piecelist).


-spec increment(pieceset(), array()) -> array().
increment(Pieceset, Numpeers) ->
    Piecelist = etorrent_pieceset:to_list(Pieceset),
    lists:foldl(fun(Index, Acc) ->
        PrevCount = array:get(Index, Acc),
        array:set(Index, PrevCount + 1, Acc)
    end, Numpeers, Piecelist).


-spec send_updates(pieceset() | pos_integer(), [#watcher{}], array()) -> ok.
send_updates(Index, Watchers, Numpeers) when is_integer(Index) ->
    Matching = [Watch || #watcher{pieceset=Watchedset}=Watch <- Watchers,
        etorrent_pieceset:is_member(Index, Watchedset)],
    [send_update(Watcher, Numpeers) || Watcher <- Matching],
    ok;

send_updates(Pieceset, Watchers, Numpeers) ->
    IsMatching = fun(Watchedset) ->
        Intersection = etorrent_pieceset:intersection(Pieceset, Watchedset),
        not etorrent_pieceset:is_empty(Intersection)
    end,
    Matching = [Watch || #watcher{pieceset=Watchedset}=Watch <- Watchers,
        IsMatching(Watchedset)],
    [send_update(Watcher, Numpeers) || Watcher <- Matching],
    ok.


-spec send_update(#watcher{}, array()) -> ok.
send_update(Watcher, Numpeers) ->
    #watcher{
        pid=Pid,
        ref=Ref,
        tag=Tag,
        pieceset=Pieceset} = Watcher,
    Piecelist = sorted_piecelist(Pieceset, Numpeers),
    Pid ! {scarcity, Ref, Tag, Piecelist},
    ok.


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(scarcity, ?MODULE).
-define(pieceset, etorrent_pieceset).

pieces(Pieces) ->
    ?pieceset:from_list(Pieces, 8).

scarcity_server_test_() ->
    {setup,
        fun()  -> application:start(gproc) end,
        fun(_) -> application:stop(gproc) end,
        [?_test(register_case()),
         ?_test(server_registers_case()),
         ?_test(initial_ordering_case()),
         ?_test(empty_ordering_case()),
         ?_test(init_pieceset_case()),
         ?_test(one_available_case()),
         ?_test(decrement_on_exit_case())]}.

register_case() ->
    true = ?scarcity:register_scarcity_server(0),
    ?assertEqual(self(), ?scarcity:lookup_scarcity_server(0)),
    ?assertEqual(self(), ?scarcity:await_scarcity_server(0)).

server_registers_case() ->
    {ok, Pid} = ?scarcity:start_link(1),
    ?assertEqual(Pid, ?scarcity:lookup_scarcity_server(1)).

initial_ordering_case() ->
    {ok, _} = ?scarcity:start_link(2),
    {ok, Order} = ?scarcity:get_order(2, pieces([0,1,2,3,4,5,6,7])),
    ?assertEqual([0,1,2,3,4,5,6,7], Order).

empty_ordering_case() ->
    {ok, _} = ?scarcity:start_link(3),
    {ok, Order} = ?scarcity:get_order(3, pieces([])),
    ?assertEqual([], Order).

init_pieceset_case() ->
    {ok, _} = ?scarcity:start_link(4),
    ?assertEqual(ok, ?scarcity:add_peer(4, pieces([]))).

one_available_case() ->
    {ok, _} = ?scarcity:start_link(5),
    ok = ?scarcity:add_peer(5, pieces([])),
    ?assertEqual(ok, ?scarcity:add_piece(5, 0, pieces([0]))),
    Pieces  = pieces([0,1,2,3,4,5,6,7]),
    {ok, Order} = ?scarcity:get_order(5, Pieces),
    ?assertEqual([1,2,3,4,5,6,7,0], Order).

decrement_on_exit_case() ->
    {ok, _} = ?scarcity:start_link(6),
    Main = self(),
    Pid = spawn_link(fun() ->
        ok = ?scarcity:add_peer(6, pieces([0])),
        ok = ?scarcity:add_piece(6, 2, pieces([0,2])),
        Main ! done,
        receive die -> ok end
    end),
    receive done -> ok end,
    Pieces  = ?pieceset:from_list([0,1,2,3,4,5,6,7], 8),
    {ok, O1} = ?scarcity:get_order(6, pieces([0,1,2,3,4,5,6,7])),
    ?assertEqual([1,3,4,5,6,7,0,2], O1),
    Ref = monitor(process, Pid),
    Pid ! die,
    receive {'DOWN', Ref, _, _, _} -> ok end,
    {ok, O2} = ?scarcity:get_order(6, Pieces),
    ?assertEqual([0,1,2,3,4,5,6,7], O2).

-endif.
