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
%% # Change notifications
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
%% Change notifications are rate limitied to an interval specified by the
%% client when the client subscription is initialialized. If an update
%% is triggered too son after a prevous update the update is supressed
%% and an update is scheduled to be sent once the interval has passed. 
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
         start_link/2,
         add_peer/2,
         add_piece/3,
         get_order/2,
         watch/3,
         unwatch/2]).

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
-type timeserver() :: etorrent_timer:timeserver().

-record(watcher, {
    pid :: pid(),
    ref :: reference(),
    tag :: term(),
    pieceset :: pieceset(),
    interval :: pos_integer(),
    changed  :: boolean(),
    timer_ref :: none | reference()}).

%% Watcher states:
%% waiting: changed=false, timer_ref=none
%% limited: changed=false, timer_ref=reference()
%% updated: changed=true,  timer_ref=reference()

-record(state, {
    torrent_id :: torrent_id(),
    timeserver :: timeserver(),
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
    start_link(TorrentID, native).


-spec start_link(torrent_id(), timeserver()) -> {ok, pid()}.
start_link(TorrentID, Timeserver) ->
    gen_server:start_link(?MODULE, [TorrentID, Timeserver], []).


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
-spec watch(torrent_id(), term(), pieceset()) ->
    {ok, reference(), [pos_integer()]}.
watch(TorrentID, Tag, Pieceset) ->
    watch(TorrentID, Tag, Pieceset, 5000).


%% @doc Receive updates to changes in scarcity
%%
%% @end
-spec watch(torrent_id(), term(), pieceset(), pos_integer()) ->
    {ok, reference(), [pos_integer()]}.
watch(TorrentID, Tag, Pieceset, Interval) ->
    SrvPid = lookup_scarcity_server(TorrentID),
    gen_server:call(SrvPid, {watch, self(), Interval, Tag, Pieceset}).

%% @doc Cancel updates to changes in scarcity
%%
%% @end
-spec unwatch(torrent_id(), reference()) -> ok.
unwatch(TorrentID, Ref) ->
    SrvPid = lookup_scarcity_server(TorrentID),
    gen_server:call(SrvPid, {unwatch, Ref}).


%% @private
init([TorrentID, Timeserver]) ->
    register_scarcity_server(TorrentID),
    InitState = #state{
        torrent_id=TorrentID,
        timeserver=Timeserver,
        num_peers=array:new([{default, 0}]),
        peer_monitors=etorrent_monitorset:new(),
        watchers=[]},
    {ok, InitState}.


%% @private
handle_call({add_peer, PeerPid, Pieceset}, _, State) ->
    #state{
        timeserver=Time,
        peer_monitors=Monitors,
        num_peers=Numpeers,
        watchers=Watchers} = State,
    NewNumpeers = increment(Pieceset, Numpeers),
    NewMonitors = etorrent_monitorset:insert(PeerPid, Pieceset, Monitors),
    NewWatchers = send_updates(Pieceset, Watchers, NewNumpeers, Time),
    NewState = State#state{
        peer_monitors=NewMonitors,
        num_peers=NewNumpeers,
        watchers=NewWatchers},
    {reply, ok, NewState};

handle_call({add_piece, Pid, PieceIndex, Pieceset}, _, State) ->
    #state{
        timeserver=Time,
        peer_monitors=Monitors,
        num_peers=Numpeers,
        watchers=Watchers} = State,
    Prev = array:get(PieceIndex, Numpeers),
    NewNumpeers = array:set(PieceIndex, Prev + 1, Numpeers),
    NewMonitors = etorrent_monitorset:update(Pid, Pieceset, Monitors),
    NewWatchers = send_updates(PieceIndex, Watchers, NewNumpeers, Time),
    NewState = State#state{
        peer_monitors=NewMonitors,
        num_peers=NewNumpeers,
        watchers=NewWatchers},
    {reply, ok, NewState};

handle_call({get_order, Pieceset}, _, State) ->
    #state{num_peers=Numpeers} = State,
    Piecelist = sorted_piecelist(Pieceset, Numpeers),
    {reply, {ok, Piecelist}, State};

handle_call({watch, Pid, Interval, Tag, Pieceset}, _, State) ->
    #state{timeserver=Time, num_peers=Numpeers, watchers=Watchers} = State,
    %% Use a monitor reference as the subscription reference,
    %% this let's us tear down subscriptions when client processes
    %% crash. Currently the interface of the monitorset module does
    %% not let us associate values with monitor references so there
    %% is no benefit to using it in this case.
    MRef = monitor(process, Pid),
    TRef = etorrent_timer:start_timer(Time, Interval, self(), MRef),
    Watcher = #watcher{
        pid=Pid,
        ref=MRef,
        tag=Tag,
        pieceset=Pieceset,
        interval=Interval,
        %% The initial state of a watcher is limited.
        changed=false,
        timer_ref=TRef},
    NewWatchers = [Watcher|Watchers],
    NewState = State#state{watchers=NewWatchers},
    Piecelist = sorted_piecelist(Pieceset, Numpeers),
    {reply, {ok, MRef, Piecelist}, NewState};

handle_call({unwatch, MRef}, _, State) ->
    #state{timeserver=Time, watchers=Watchers} = State,
    demonitor(MRef),
    Watcher = lists:keyfind(MRef, #watcher.ref, Watchers),
    #watcher{timer_ref=TRef} = Watcher,
    case TRef of none -> ok; _ -> etorrent_timer:cancel(Time, TRef) end,
    NewWatchers = lists:keydelete(MRef, #watcher.ref, Watchers),
    NewState = State#state{watchers=NewWatchers},
    {reply, ok, NewState}.


%% @private
handle_cast(_, State) ->
    {noreply, State}.


%% @private
handle_info({'DOWN', MRef, process, Pid, _}, State) ->
    #state{
        timeserver=Time,
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
            NewWatchers = send_updates(Pieceset, Watchers, NewNumpeers, Time),
            INewState = State#state{
                peer_monitors=NewMonitors,
                num_peers=NewNumpeers,
                watchers=NewWatchers},
            INewState;
        false ->
            Watcher = lists:keyfind(MRef, #watcher.ref, Watchers),
            #watcher{timer_ref=TRef} = Watcher,
            case TRef of none -> ok; _ -> erlang:cancel_timer(TRef) end,
            NewWatchers = lists:keydelete(MRef, #watcher.ref, Watchers),
            State#state{watchers=NewWatchers}
    end,
    {noreply, NewState};

handle_info({timeout, _, MRef}, State) ->
    #state{timeserver=Time, num_peers=Numpeers, watchers=Watchers} = State,
    Watcher = lists:keyfind(MRef, #watcher.ref, Watchers),
    #watcher{changed=Changed} = Watcher,
    NewWatcher = case Changed of
        %% If the watcher is still in the 'limited' state no update
        %% should be sent and the watcher should enter 'waiting'.
        false ->
            Watcher#watcher{timer_ref=none};
        %% If the watcher is in the 'updated' state an update should
        %% be sent and the watcher should enter 'limited'.
        true ->
            NewTRef = send_update(Watcher, Numpeers, Time),
            Watcher#watcher{changed=false, timer_ref=NewTRef}
    end,
    NewWatchers = lists:keyreplace(MRef, #watcher.ref, Watchers, NewWatcher),
    NewState = State#state{watchers=NewWatchers},
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


-spec send_updates(pieceset() | pos_integer(), [#watcher{}],
                   array(), timeserver()) -> [#watcher{}].
send_updates(Index, Watchers, Numpeers, Time) when is_integer(Index) ->
    HasChanged = fun(Watchedset) ->
        etorrent_pieceset:is_member(Index, Watchedset)
    end,
    [send_update(HasChanged, Watcher, Numpeers, Time) || Watcher <- Watchers];

send_updates(Pieceset, Watchers, Numpeers, Time) ->
    HasChanged = fun(Watchedset) ->
        Inter = etorrent_pieceset:intersection(Pieceset, Watchedset),
        not etorrent_pieceset:is_empty(Inter)
    end,
    [send_update(HasChanged, Watcher, Numpeers, Time) || Watcher <- Watchers].

-spec send_update(fun((pieceset()) -> boolean()), #watcher{},
                  array(), timeserver()) -> ok.
send_update(HasChanged, Watcher, Numpeers, Time) ->
    #watcher{
        pieceset=Pieceset,
        changed=Changed,
        timer_ref=TRef} = Watcher,
    case {Changed, TRef} of
        %% waiting
        {false, none} ->
            case HasChanged(Pieceset) of
                %% waiting -> limited
                true ->
                    NewTRef = send_update(Watcher, Numpeers, Time),
                    Watcher#watcher{timer_ref=NewTRef};
                %% waiting -> waiting
                false ->
                    Watcher
            end;
        %% limited -> updated
        {false, TRef} ->
            Watcher#watcher{changed=HasChanged(Pieceset)};
        %% updated -> updated
        {true, TRef} ->
            Watcher
    end.

-spec send_update(#watcher{}, array(), timeserver()) -> reference().
send_update(Watcher, Numpeers, Time) ->
    #watcher{
        pid=Pid,
        ref=MRef,
        tag=Tag,
        pieceset=Pieceset,
        interval=Interval} = Watcher,
    Piecelist = sorted_piecelist(Pieceset, Numpeers),
    Pid ! {scarcity, MRef, Tag, Piecelist},
    etorrent_timer:start_timer(Time, Interval, self(), MRef).


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(scarcity, ?MODULE).
-define(pieceset, etorrent_pieceset).
-define(timer, etorrent_timer).

pieces(Pieces) ->
    ?pieceset:from_list(Pieces, 8).

scarcity_server_test_() ->
    {setup,
        fun()  -> application:start(gproc) end,
        fun(_) -> application:stop(gproc) end,
        [?_test(register_case()),
         ?_test(server_registers_case()),
         ?_test(initial_ordering_case(test_data(2))),
         ?_test(empty_ordering_case(test_data(3))),
         ?_test(init_pieceset_case(test_data(4))),
         ?_test(one_available_case(test_data(5))),
         ?_test(decrement_on_exit_case(test_data(6))),
         ?_test(init_watch_case(test_data(7))),
         ?_test(add_peer_update_case(test_data(8))),
         ?_test(add_piece_update_case(test_data(9))),
         ?_test(aggregate_update_case(test_data(12))),
         ?_test(noaggregate_update_case(test_data(13))),
         ?_test(peer_exit_update_case(test_data(10))),
         ?_test(local_unwatch_case(test_data(11)))]}.

test_data(N) ->
    {ok, Time} = ?timer:start_link(queue),
    {ok, Pid} = ?scarcity:start_link(N, Time),
    {N, Time, Pid}.

register_case() ->
    true = ?scarcity:register_scarcity_server(0),
    ?assertEqual(self(), ?scarcity:lookup_scarcity_server(0)),
    ?assertEqual(self(), ?scarcity:await_scarcity_server(0)).

server_registers_case() ->
    {ok, Pid} = ?scarcity:start_link(1),
    ?assertEqual(Pid, ?scarcity:lookup_scarcity_server(1)).

initial_ordering_case({N, Time, Pid}) ->
    {ok, Order} = ?scarcity:get_order(N, pieces([0,1,2,3,4,5,6,7])),
    ?assertEqual([0,1,2,3,4,5,6,7], Order).

empty_ordering_case({N, Time, Pid}) ->
    {ok, Order} = ?scarcity:get_order(3, pieces([])),
    ?assertEqual([], Order).

init_pieceset_case({N, Time, Pid}) ->
    ?assertEqual(ok, ?scarcity:add_peer(4, pieces([]))).

one_available_case({N, Time, Pid}) ->
    ok = ?scarcity:add_peer(N, pieces([])),
    ?assertEqual(ok, ?scarcity:add_piece(N, 0, pieces([0]))),
    Pieces  = pieces([0,1,2,3,4,5,6,7]),
    {ok, Order} = ?scarcity:get_order(N, Pieces),
    ?assertEqual([1,2,3,4,5,6,7,0], Order).

decrement_on_exit_case({N, Time, _}) ->
    Main = self(),
    Pid = spawn_link(fun() ->
        ok = ?scarcity:add_peer(N, pieces([0])),
        ok = ?scarcity:add_piece(N, 2, pieces([0,2])),
        Main ! done,
        receive die -> ok end
    end),
    receive done -> ok end,
    Pieces  = ?pieceset:from_list([0,1,2,3,4,5,6,7], 8),
    {ok, O1} = ?scarcity:get_order(N, pieces([0,1,2,3,4,5,6,7])),
    ?assertEqual([1,3,4,5,6,7,0,2], O1),
    Ref = monitor(process, Pid),
    Pid ! die,
    receive {'DOWN', Ref, _, _, _} -> ok end,
    {ok, O2} = ?scarcity:get_order(N, Pieces),
    ?assertEqual([0,1,2,3,4,5,6,7], O2).

init_watch_case({N, Time, Pid}) ->
    {ok, Ref, Order} = ?scarcity:watch(N, seven, pieces([0,2,4,6])),
    ?assert(is_reference(Ref)),
    ?assertEqual([0,2,4,6], Order).

add_peer_update_case({N, Time, Pid}) ->
    {ok, Ref, _} = ?scarcity:watch(N, eight, pieces([0,2,4,6])),
    ?assertEqual(1, ?timer:fire(Time)),
    ok = ?scarcity:add_peer(N, pieces([0,2])),
    receive
        {scarcity, Ref, Tag, Order} ->
            ?assertEqual(eight, Tag),
            ?assertEqual([4,6,0,2], Order);
        Other ->
            ?assertEqual(make_ref(), Other)
    end.

add_piece_update_case({N, Time, Pid}) ->
    {ok, Ref, _} = ?scarcity:watch(9, nine, pieces([0,2,4,6])),
    ok = ?scarcity:add_peer(N, pieces([])),
    ok = ?scarcity:add_piece(N, 2, pieces([2])),
    ?assertEqual(5000, ?timer:step(Time)),
    ?assertEqual(1, ?timer:fire(Time)),
    receive
        {scarcity, Ref, nine, Order} ->
            ?assertEqual([0,4,6,2], Order)
    end.

aggregate_update_case({N, Time, Pid}) ->
    {ok, Ref, _} = ?scarcity:watch(N, aggr, pieces([0,2,4,6])),
    %% Assert that peer is limited by default
    ?assertEqual(5000, ?timer:step(Time)),
    ok = ?scarcity:add_peer(N, pieces([2])),
    ok = ?scarcity:add_piece(N, 0, pieces([0,2])),
    ?assertEqual(1, ?timer:fire(Time)),
    receive
        {scarcity, Ref, aggr, [4,6,0,2]} -> ok;
        Other -> ?assertEqual(make_ref(), Other)
        after 0 -> ?assert(false)
    end.

noaggregate_update_case({N, Time, Pid}) ->
    {ok, Ref, _} = ?scarcity:watch(N, aggr, pieces([0,2,4,6])),
    %% Assert that peer is limited by default
    ?assertEqual(5000, ?timer:step(Time)),
    ok = ?scarcity:add_peer(N, pieces([2])),
    ?assertEqual(1, ?timer:fire(Time)),
    receive
        {scarcity, Ref, aggr, [0,4,6,2]} -> ok;
        O1 -> ?assertEqual(make_ref(), O1)
        after 0 -> ?assert(false)
    end,
    ok = ?scarcity:add_piece(N, 0, pieces([0,2])),
    ?assertEqual(1, ?timer:fire(Time)),
    receive
        {scarcity, Ref, aggr, [4,6,0,2]} -> ok;
        O2 -> ?assertEqual(make_ref(), O2)
        after 0 -> ?assert(false)
    end.



peer_exit_update_case({N, Time, _}) ->
    Main = self(),
    Pid = spawn_link(fun() ->
        ok = ?scarcity:add_peer(N, pieces([0,1,2,3])),
        Main ! done,
        receive die -> ok end
    end),
    receive done -> ok end,
    {ok, Ref, _} = ?scarcity:watch(N, ten, pieces([0,2,4,6])),
    Pid ! die,
    ?assertEqual(1, ?timer:fire(Time)),
    receive
        {scarcity, Ref, ten, Order} ->
            ?assertEqual([0,2,4,6], Order)
    end.

local_unwatch_case({N, Time, Pid}) ->
    {ok, Ref, _} = ?scarcity:watch(N, eleven, pieces([0,2,4,6])),
    ?assertEqual(ok, ?scarcity:unwatch(N, Ref)),
    ok = ?scarcity:add_peer(N, pieces([0,1,2,3,4,5,6,7])),
    %% Assume that the message is sent before the add_peer call returns
    receive
        {scarcity, Ref, _, _} ->
            ?assert(false)
        after 0 ->
            ?assert(true)
    end.

-endif.
