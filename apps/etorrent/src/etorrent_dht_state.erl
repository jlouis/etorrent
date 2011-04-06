%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc A Server for maintaining the the routing table in DHT
%%
%% @todo Document all exported functions.
%%
%% This module implements a server maintaining the
%% DHT routing table. The nodes in the routing table
%% is distributed across a set of buckets. The bucket
%% set is created incrementally based on the local node id.
%%
%% The set of buckets, id ranges, is used to limit
%% the number of nodes in the routing table. The routing
%% table must only contain ?K nodes that fall within the
%% range of each bucket.
%%
%% A node is considered disconnected if it does not respond to
%% a ping query after 10 minutes of inactivity. Inactive nodes
%% are kept in the routing table but are not propagated to
%% neighbouring nodes through responses through find_node
%% and get_peers responses.
%% This allows the node to keep the routing table intact
%% while operating in offline mode. It also allows the node
%% to operate with a partial routing table without exposing
%% inconsitencies to neighboring nodes.
%%
%% A bucket is refreshed once the least recently active node
%% has been inactive for 5 minutes. If a replacement for the
%% least recently active node can't be replaced, the server
%% should wait at least 5 minutes before attempting to find
%% a replacement again.
%%
%% The timeouts (expiry times) in this server is managed
%% using a pair containg the time that a node/bucket was
%% last active and a reference to the currently active timer.
%%
%% The activity time is used to validate the timeout messages
%% sent to the server in those cases where the timer was cancelled
%% inbetween that the timer fired and the server received the timeout
%% message. The activity time is also used to calculate when
%% future timeout should occur.
%%
%% @end
-module(etorrent_dht_state).
-behaviour(gen_server).
-import(ordsets, [add_element/2, del_element/2, subtract/2]).
-import(error_logger, [info_msg/2, error_msg/2]).
-define(K, 8).
-define(in_range(IDExpr, MinExpr, MaxExpr),
    ((IDExpr >= MinExpr) and (IDExpr < MaxExpr))).


-export([srv_name/0,
         start_link/1,
         node_id/0,
         safe_insert_node/2,
         safe_insert_node/3,
         safe_insert_nodes/1,
         unsafe_insert_node/3,
         unsafe_insert_nodes/1,
         is_interesting/3,
         closest_to/1,
         closest_to/2,
         log_request_timeout/3,
         log_request_success/3,
         log_request_from/3,
         keepalive/3,
         refresh/3,
         dump_state/0,
         dump_state/1,
         dump_state/3,
         load_state/1]).

-type ipaddr() :: etorrent_types:ipaddr().
-type nodeid() :: etorrent_types:nodeid().
-type portnum() :: etorrent_types:portnum().
-type nodeinfo() :: etorrent_types:nodeinfo().

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {
    node_id,
    buckets=b_new(), % The actual routing table
    node_timers=timer_tree(), % Node activity times and timeout references
    buck_timers=timer_tree(),% Bucker activity times and timeout references
    node_timeout=10*60*1000,  % Default node keepalive timeout
    buck_timeout=5*60*1000,   % Default bucket refresh timeout
    state_file="/tmp/dht_state"}). % Path to persistent state
%
% The bucket refresh timeout is the amount of time that the
% server will tolerate a node to be disconnected before it
% attempts to refresh the bucket.
%


%
% The server has started to use integer IDs internally, before the
% rest of the program does that, run these functions whenever an ID
% enters or leaves this process.
%
ensure_bin_id(ID) -> ID.
ensure_int_id(ID) -> ID.

srv_name() ->
    etorrent_dht_state_server.

start_link(StateFile) ->
    gen_server:start_link({local, srv_name()}, ?MODULE, [StateFile], []).

-spec node_id() -> nodeid().
node_id() ->
    gen_server:call(srv_name(), {node_id}).

%
% Check if a node is available and lookup its node id by issuing
% a ping query to it first. This function must be used when we
% don't know the node id of a node.
%
-spec safe_insert_node(ipaddr(), portnum()) ->
    {'error', 'timeout'} | boolean().
safe_insert_node(IP, Port) ->
    case unsafe_ping(IP, Port) of
        pang -> {error, timeout};
        ID   -> unsafe_insert_node(ID, IP, Port)
    end.

%
% Check if a node is available and verify its node id by issuing
% a ping query to it first. This function must be used when we
% want to verify the identify and status of a node.
%
% This function will return {error, timeout} if the node is unreachable
% or has changed identity, false if the node is not interesting or wasnt
% inserted into the routing table, true if the node was interesting and was
% inserted into the routing table.
%
-spec safe_insert_node(nodeid(), ipaddr(), portnum()) ->
    {'error', 'timeout'} | boolean().
safe_insert_node(ID, IP, Port) ->
    case is_interesting(ID, IP, Port) of
        false -> false;
        true ->
            % Since this clause will be reached every time this node
            % receives a query from a node that is interesting, use the
            % unsafe_ping function to avoid repeatedly issuing ping queries
            % to nodes that won't reply to them.
            case unsafe_ping(IP, Port) of
                ID   -> unsafe_insert_node(ID, IP, Port);
                pang -> {error, timeout};
                _    -> {error, timeout}
        end
    end.

-spec safe_insert_nodes(list(nodeinfo())) -> 'ok'.
safe_insert_nodes(NodeInfos) ->
    [spawn_link(?MODULE, safe_insert_node, [ID, IP, Port])
     || {ID, IP, Port} <- NodeInfos],
    ok.

%
% Blindly insert a node into the routing table. Use this function when
% inserting a node that was found and successfully queried in a find_node
% or get_peers search.
% This function returns a boolean value to indicate to the caller if the
% node was actually inserted into the routing table or not.
%
-spec unsafe_insert_node(nodeid(), ipaddr(), portnum()) ->
    boolean().
unsafe_insert_node(ID, IP, Port) ->
    _WasInserted = gen_server:call(srv_name(), {insert_node, ID, IP, Port}).

-spec unsafe_insert_nodes(list(nodeinfo())) -> 'ok'.
unsafe_insert_nodes(NodeInfos) ->
    [spawn_link(?MODULE, unsafe_insert_node, [ID, IP, Port])
    || {ID, IP, Port} <- NodeInfos],
    ok.

%
% Check if node would fit into the routing table. This
% function is used by the safe_insert_node(s) function
% to avoid issuing ping-queries to every node sending
% this node a query.
%

-spec is_interesting(nodeid(), ipaddr(), portnum()) -> boolean().
is_interesting(ID, IP, Port) ->
    gen_server:call(srv_name(), {is_interesting, ID, IP, Port}).

-spec closest_to(nodeid()) -> list(nodeinfo()).
closest_to(NodeID) ->
    closest_to(NodeID, 8).

-spec closest_to(nodeid(), pos_integer()) -> list(nodeinfo()).
closest_to(NodeID, NumNodes) ->
    gen_server:call(srv_name(), {closest_to, NodeID, NumNodes}).

-spec log_request_timeout(nodeid(), ipaddr(), portnum()) -> 'ok'.
log_request_timeout(ID, IP, Port) ->
    Call = {request_timeout, ID, IP, Port},
    gen_server:call(srv_name(), Call).

-spec log_request_success(nodeid(), ipaddr(), portnum()) -> 'ok'.
log_request_success(ID, IP, Port) ->
    Call = {request_success, ID, IP, Port},
    gen_server:call(srv_name(), Call).

-spec log_request_from(nodeid(), ipaddr(), portnum()) -> 'ok'.
log_request_from(ID, IP, Port) ->
    Call = {request_from, ID, IP, Port},
    gen_server:call(srv_name(), Call).

dump_state() ->
    gen_server:call(srv_name(), {dump_state}).

dump_state(Filename) ->
    gen_server:call(srv_name(), {dump_state, Filename}).

-spec keepalive(nodeid(), ipaddr(), portnum()) -> 'ok'.
keepalive(ID, IP, Port) ->
    case safe_ping(IP, Port) of
        ID    -> log_request_success(ID, IP, Port);
        pang  -> log_request_timeout(ID, IP, Port);
        _     -> log_request_timeout(ID, IP, Port)
    end.

spawn_keepalive(ID, IP, Port) ->
    spawn(?MODULE, keepalive, [ID, IP, Port]).

%
% Issue a ping query to a node, this function should always be used
% when checking if a node that is already a member of the routing table
% is online.
%
safe_ping(IP, Port) ->
    etorrent_dht_net:ping(IP, Port).

%
% unsafe_ping overrides the behaviour of etorrent_net:ping/2 by
% avoiding to issue ping queries to nodes that are unlikely to
% be reachable. If a node has not been queried before, a safe_ping
% will always be performed.
%
unsafe_ping(IP, Port) ->
    case ets:lookup(unreachable_tab(), {IP, Port}) of
        [_|_] ->
            pang;
        [] ->
            case safe_ping(IP, Port) of
                pang ->
                    RandNode = random_node_tag(),
                    DelSpec = [{{'_', RandNode}, [], [true]}],
                    _ = ets:select_delete(unreachable_tab(), DelSpec),
                    ets:insert(unreachable_tab(), {{IP, Port}, RandNode}),
                    {error, timeout};
                NodeID ->
                    NodeID
            end
    end.

%
% Refresh the contents of a bucket by issuing find_node queries to each node
% in the bucket until enough nodes that falls within the range of the bucket
% has been returned to replace the inactive nodes in the bucket.
%
-spec refresh(any(), list(nodeinfo()), list(nodeinfo())) -> 'ok'.
refresh(Range, Inactive, Active) ->
    % Try to refresh the routing table using the inactive nodes first,
    % If they turn out to be reachable the problem's solved.
    do_refresh(Range, Inactive ++ Active, []).

do_refresh(_, [], _) ->
    ok; % @todo - perform a find_node_search here?
do_refresh(Range, [{ID, IP, Port}|T], IDs) ->
    Continue = case etorrent_dht_net:find_node(IP, Port, ID) of
        {error, timeout} ->
            true;
        {_, CloseNodes} ->
            do_refresh_inserts(Range, CloseNodes)
    end,
    case Continue of
        false -> ok;
        true  -> do_refresh(Range, T, [ID|IDs])
    end.

do_refresh_inserts({_, _}, []) ->
    true;
do_refresh_inserts({Min, Max}=Range, [{ID, IP, Port}|T])
when ?in_range(ID, Min, Max) ->
    case safe_insert_node(ID, IP, Port) of
        {error, timeout} ->
            do_refresh_inserts(Range, T);
        true ->
            do_refresh_inserts(Range, T);
        false ->
            safe_insert_nodes(T),
            false
    end;

do_refresh_inserts(Range, [{ID, IP, Port}|T]) ->
    _ = safe_insert_node(ID, IP, Port),
    do_refresh_inserts(Range, T).

spawn_refresh(Range, InputInactive, InputActive) ->
    Inactive = [{ensure_bin_id(ID), IP, Port}
               || {ID, IP, Port} <- InputInactive],
    Active   = [{ensure_bin_id(ID), IP, Port}
               || {ID, IP, Port} <- InputActive],
    spawn(?MODULE, refresh, [Range, Inactive, Active]).


max_unreachable() ->
    128.

unreachable_tab() ->
    etorrent_dht_unreachable_cache_tab.

random_node_tag() ->
    random:seed(now()),
    random:uniform(max_unreachable()).

%% @private
init([StateFile]) ->
    % Initialize the table of unreachable nodes when the server is started.
    % The safe_ping and unsafe_ping functions aren't exported outside of
    % of this module so they should fail unless the server is not running.
    _ = case ets:info(unreachable_tab()) of
        undefined ->
            ets:new(unreachable_tab(), [named_table, public, bag]);
        _ -> ok
    end,


    {NodeID, NodeList} = load_state(StateFile),

    % Insert any nodes loaded from the persistent state later
    % when we are up and running. Use unsafe insertions or the
    % whole state will be lost if etorrent starts without
    % internet connectivity.
    [spawn(?MODULE, unsafe_insert_node, [ensure_bin_id(ID), IP, Port])
    || {ID, IP, Port} <- NodeList],

    #state{
        buckets=Buckets,
        buck_timers=InitBTimers,
        node_timeout=NTimeout,
        buck_timeout=BTimeout} = #state{},

    Now = now(),
    BTimers = lists:foldl(fun(Range, Acc) ->
        BTimer = bucket_timer_from(Now, NTimeout, Now, BTimeout, Range),
        add_timer(Range, Now, BTimer, Acc)
    end, InitBTimers, b_ranges(Buckets)),

    State = #state{
        node_id=ensure_int_id(NodeID),
        buck_timers=BTimers,
        state_file=StateFile},
    {ok, State}.

%% @private
handle_call({is_interesting, InputID, IP, Port}, _From, State) ->
    ID = ensure_int_id(InputID),
    #state{
        node_id=Self,
        buckets=Buckets,
        node_timeout=NTimeout,
        node_timers=NTimers} = State,
    IsInteresting = case b_is_member(ID, IP, Port, Buckets) of
        true -> false;
        false ->
            BMembers = b_members(ID, Buckets),
            Inactive = inactive_nodes(BMembers, NTimeout, NTimers),
            case (Inactive =/= []) or (length(BMembers) < ?K) of
                true -> true;
                false ->
                    TryBuckets = b_insert(Self, ID, IP, Port, Buckets),
                    b_is_member(ID, IP, Port, TryBuckets)
            end
    end,
    {reply, IsInteresting, State};

handle_call({insert_node, InputID, IP, Port}, _From, State) ->
    ID   = ensure_int_id(InputID),
    Now  = now(),
    Node = {ID, IP, Port},
    #state{
        node_id=Self,
        buckets=PrevBuckets,
        node_timers=PrevNTimers,
        buck_timers=PrevBTimers,
        node_timeout=NTimeout,
        buck_timeout=BTimeout} = State,

    IsPrevMember = b_is_member(ID, IP, Port, PrevBuckets),
    Inactive = case IsPrevMember of
        true  -> [];
        false ->
            PrevBMembers = b_members(ID, PrevBuckets),
            inactive_nodes(PrevBMembers, NTimeout, PrevNTimers)
    end,

    {NewBuckets, Replace} = case {IsPrevMember, Inactive} of
        {true, _} ->
            % If the node is already a member of the node set,
            % don't change a thing
            {PrevBuckets, none};

        {false, []} ->
            % If there are no disconnected nodes in the bucket
            % insert it anyways and check later if it was actually added
            {b_insert(Self, ID, IP, Port, PrevBuckets), none};

        {false, [{OID, OIP, OPort}=Old|_]} ->
            % If there is one or more disconnected nodes in the bucket
            % Remove the old one and insert the new node.
            TmpBuckets = b_delete(OID, OIP, OPort, PrevBuckets),
            {b_insert(Self, ID, IP, Port, TmpBuckets), Old}
    end,

    % If the new node replaced a new, remove all timer and access time
    % information from the state
    TmpNTimers = case Replace of
        none ->
            PrevNTimers;
        {_, _, _}=DNode ->
            del_timer(DNode, PrevNTimers)
    end,



    IsNewMember = b_is_member(ID, IP, Port, NewBuckets),
    NewNTimers  = case {IsPrevMember, IsNewMember} of
        {false, false} ->
            TmpNTimers;
        {true, true} ->
            TmpNTimers;
        {false, true}  ->
            NTimer = node_timer_from(Now, NTimeout, Node),
            add_timer(Node, Now, NTimer, TmpNTimers)
    end,

    NewBTimers = case {IsPrevMember, IsNewMember} of
        {false, false} ->
            PrevBTimers;
        {true, true} ->
            PrevBTimers;

        {false, true} ->
            AllPrevRanges = b_ranges(PrevBuckets),
            AllNewRanges  = b_ranges(NewBuckets),

            DelRanges  = subtract(AllPrevRanges, AllNewRanges),
            NewRanges  = subtract(AllNewRanges, AllPrevRanges),

            DelBTimers = lists:foldl(fun(Range, Acc) ->
                del_timer(Range, Acc)
            end, PrevBTimers, DelRanges),

            lists:foldl(fun(Range, Acc) ->
                BMembers = b_members(Range, NewBuckets),
                LRecent = least_recent(BMembers, NewNTimers),
                BTimer = bucket_timer_from(
                             Now, BTimeout, LRecent, NTimeout, Range),
                add_timer(Range, Now, BTimer, Acc)
            end, DelBTimers, NewRanges)
    end,
    NewState = State#state{
        buckets=NewBuckets,
        node_timers=NewNTimers,
        buck_timers=NewBTimers},
    {reply, ((not IsPrevMember) and IsNewMember), NewState};




handle_call({closest_to, InputID, NumNodes}, _, State) ->
    ID = ensure_int_id(InputID),
    #state{
        buckets=Buckets,
        node_timers=NTimers,
        node_timeout=NTimeout} = State,
    AllNodes   = b_node_list(Buckets),
    Active     = active_nodes(AllNodes, NTimeout, NTimers),
    CloseNodes = etorrent_dht:closest_to(ID, Active, NumNodes),
    {reply, CloseNodes, State};


handle_call({request_timeout, InputID, IP, Port}, _, State) ->
    ID   = ensure_int_id(InputID),
    Node = {ID, IP, Port},
    Now  = now(),
    #state{
        buckets=Buckets,
        node_timeout=NTimeout,
        node_timers=PrevNTimers} = State,

    NewNTimers = case b_is_member(ID, IP, Port, Buckets) of
        false ->
            State;
        true ->
            {LActive, _} = get_timer(Node, PrevNTimers),
            TmpNTimers   = del_timer(Node, PrevNTimers),
            NTimer       = node_timer_from(Now, NTimeout, Node),
            add_timer(Node, LActive, NTimer, TmpNTimers)
    end,
    NewState = State#state{node_timers=NewNTimers},
    {reply, ok, NewState};

handle_call({request_success, InputID, IP, Port}, _, State) ->
    ID   = ensure_int_id(InputID),
    Now  = now(),
    Node = {ID, IP, Port},
    #state{
        buckets=Buckets,
        node_timers=PrevNTimers,
        buck_timers=PrevBTimers,
        node_timeout=NTimeout,
        buck_timeout=BTimeout} = State,
    NewState = case b_is_member(ID, IP, Port, Buckets) of
        false ->
            State;
        true ->
            Range = b_range(ID, Buckets),

            {NLActive, _} = get_timer(Node, PrevNTimers),
            TmpNTimers    = del_timer(Node, PrevNTimers),
            NTimer        = node_timer_from(Now, NTimeout, Node),
            NewNTimers    = add_timer(Node, NLActive, NTimer, TmpNTimers),

            {BActive, _} = get_timer(Range, PrevBTimers),
            TmpBTimers   = del_timer(Range, PrevBTimers),
            BMembers     = b_members(Range, Buckets),
            LNRecent     = least_recent(BMembers, NewNTimers),
            BTimer       = bucket_timer_from(
                               BActive, BTimeout, LNRecent, NTimeout, Range),
            NewBTimers    = add_timer(Range, BActive, BTimer, TmpBTimers),

            State#state{
                node_timers=NewNTimers,
                buck_timers=NewBTimers}
    end,
    {reply, ok, NewState};


handle_call({request_from, ID, IP, Port}, From, State) ->
    handle_call({request_success, ID, IP, Port}, From, State);

handle_call({dump_state}, _From, State) ->
    #state{
        node_id=Self,
        buckets=Buckets,
        state_file=StateFile} = State,
    catch dump_state(StateFile, Self, b_node_list(Buckets)),
    {reply, State, State};

handle_call({dump_state, StateFile}, _From, State) ->
    #state{
        node_id=Self,
        buckets=Buckets} = State,
    catch dump_state(StateFile, Self, b_node_list(Buckets)),
    {reply, ok, State};

handle_call({node_id}, _From, State) ->
    #state{node_id=Self} = State,
    {reply, ensure_bin_id(Self), State}.

%% @private
handle_cast(_, State) ->
    {noreply, State}.

%% @private
handle_info({inactive_node, InputID, IP, Port}, State) ->
    ID = ensure_int_id(InputID),
    Now = now(),
    Node = {ID, IP, Port},
    #state{
        buckets=Buckets,
        node_timers=PrevNTimers,
        node_timeout=NTimeout} = State,

    IsMember = b_is_member(ID, IP, Port, Buckets),
    HasTimed = case IsMember of
        false -> false;
        true  -> has_timed_out(Node, NTimeout, PrevNTimers)
    end,

    NewState = case {IsMember, HasTimed} of
        {false, false} ->
            State;
        {true, false} ->
            State;
        {true, true} ->
            info_msg("Node at ~w:~w timed out", [IP, Port]),
            spawn_keepalive(ensure_bin_id(ID), IP, Port),
            {LActive,_} = get_timer(Node, PrevNTimers),
            TmpNTimers  = del_timer(Node, PrevNTimers),
            NewTimer    = node_timer_from(Now, NTimeout, Node),
            NewNTimers  = add_timer(Node, LActive, NewTimer, TmpNTimers),
            State#state{node_timers=NewNTimers}
    end,
    {noreply, NewState};

handle_info({inactive_bucket, Range}, State) ->
    Now = now(),
    #state{
        buckets=Buckets,
        node_timers=NTimers,
        buck_timers=PrevBTimers,
        node_timeout=NTimeout,
        buck_timeout=BTimeout} = State,

    BucketExists = b_has_bucket(Range, Buckets),
    HasTimed = case BucketExists of
        false -> false;
        true  -> has_timed_out(Range, BTimeout, PrevBTimers)
    end,

    NewState = case {BucketExists, HasTimed} of
        {false, false} ->
            State;
        {true, false} ->
            State;
        {true, true} ->
            info_msg("Bucket timed out", []),
            BMembers   = b_members(Range, Buckets),
            _ = spawn_refresh(Range,
                    inactive_nodes(BMembers, NTimeout, NTimers),
                    active_nodes(BMembers, NTimeout, NTimers)),
            TmpBTimers = del_timer(Range, PrevBTimers),
            LRecent    = least_recent(BMembers, NTimers),
            NewTimer   = bucket_timer_from(
                            Now, BTimeout, LRecent, NTimeout, Range),
            NewBTimers = add_timer(Range, Now, NewTimer, TmpBTimers),
            State#state{buck_timers=NewBTimers}
    end,
    {noreply, NewState}.

%% @private
terminate(_, State) ->
    #state{
        node_id=Self,
        buckets=Buckets,
        state_file=StateFile} = State,
    dump_state(StateFile, Self, b_node_list(Buckets)).

dump_state(Filename, Self, NodeList) ->
    PersistentState = [{node_id, Self}, {node_set, NodeList}],
    file:write_file(Filename, term_to_binary(PersistentState)).

load_state(Filename) ->
    case file:read_file(Filename) of
        {ok, BinState} ->
            PersistentState = binary_to_term(BinState),
            {value, {_, Self}}  = lists:keysearch(node_id, 1, PersistentState),
            {value, {_, Nodes}} = lists:keysearch(node_set, 1, PersistentState),
            error_logger:info_msg("Loaded state from ~s", [Filename]),
            {Self, Nodes};

        {error, Reason} ->
            error_logger:error_msg("Failed to load state from ~s (~w)", [Filename, Reason]),
            Self  = etorrent_dht:random_id(),
            Nodes = [],
            {Self, Nodes}
    end.

%% @private
code_change(_, _, State) ->
    {ok, State}.


%
% Create a new bucket list
%
b_new() ->
    MaxID = trunc(math:pow(2, 160)),
    [{0, MaxID, []}].

%
% Insert a new node into a bucket list
%
b_insert(Self, ID, IP, Port, Buckets) ->
    true = is_integer(Self),
    true = is_integer(ID),
    b_insert_(Self, ID, IP, Port, Buckets).


b_insert_(Self, ID, IP, Port, [{Min, Max, Members}|T])
when ?in_range(ID, Min, Max), ?in_range(Self, Min, Max) ->
    NumMembers = length(Members),
    if  NumMembers < ?K ->
            NewMembers = add_element({ID, IP, Port}, Members),
            [{Min, Max, NewMembers}|T];

        NumMembers == ?K, (Max - Min) > 2 ->
            Diff  = Max - Min,
            Half  = Max - (Diff div 2),
            Lower = [N || {MID, _, _}=N <- Members, ?in_range(MID, Min, Half)],
            Upper = [N || {MID, _, _}=N <- Members, ?in_range(MID, Half, Max)],
            WithSplit = [{Min, Half, Lower}, {Half, Max, Upper}|T],
            b_insert_(Self, ID, IP, Port, WithSplit);

        NumMembers == ?K ->
           [{Min, Max, Members}|T]
    end;

b_insert_(_, ID, IP, Port, [{Min, Max, Members}|T])
when ?in_range(ID, Min, Max) ->
    NumMembers = length(Members),
    if  NumMembers < ?K ->
            NewMembers = add_element({ID, IP, Port}, Members),
            [{Min, Max, NewMembers}|T];
        NumMembers == ?K ->
            [{Min, Max, Members}|T]
    end;

b_insert_(Self, ID, IP, Port, [H|T]) ->
    [H|b_insert_(Self, ID, IP, Port, T)].

%
% Get all ranges present in a bucket list
%
b_ranges([]) ->
    [];
b_ranges([{Min, Max, _}|T]) ->
    [{Min, Max}|b_ranges(T)].

%
% Delete a node from a bucket list
%
b_delete(_, _, _, []) ->
    [];
b_delete(ID, IP, Port, [{Min, Max, Members}|T])
when ?in_range(ID, Min, Max) ->
    NewMembers = del_element({ID, IP, Port}, Members),
    [{Min, Max, NewMembers}|T];
b_delete(ID, IP, Port, [H|T]) ->
    [H|b_delete(ID, IP, Port, T)].

%
% Return all members of the bucket that this node is a member of
%
b_members({Min, Max}, [{Min, Max, Members}|_]) ->
    Members;
b_members({Min, Max}, [_|T]) ->
    b_members({Min, Max}, T);

b_members(ID, [{Min, Max, Members}|_])
when ?in_range(ID, Min, Max) ->
    Members;
b_members(ID, [_|T]) ->
    b_members(ID, T).


%
% Check if a node is a member of a bucket list
%
b_is_member(_, _, _, []) ->
    false;
b_is_member(ID, IP, Port, [{Min, Max, Members}|_])
when ?in_range(ID, Min, Max) ->
    lists:member({ID, IP, Port}, Members);
b_is_member(ID, IP, Port, [_|T]) ->
    b_is_member(ID, IP, Port, T).

%
% Check if a bucket exists in a bucket list
%
b_has_bucket({_, _}, []) ->
    false;
b_has_bucket({Min, Max}, [{Min, Max, _}|_]) ->
    true;
b_has_bucket({Min, Max}, [{_, _, _}|T]) ->
    b_has_bucket({Min, Max}, T).

%
% Return a list of all members, combined, in all buckets.
%
b_node_list([]) ->
    [];
b_node_list([{_, _, Members}|T]) ->
    Members ++ b_node_list(T).

%
% Return the range of the bucket that a node falls within
%
b_range(ID, [{Min, Max, _}|_]) when ?in_range(ID, Min, Max) ->
    {Min, Max};
b_range(ID, [_|T]) ->
    b_range(ID, T).



inactive_nodes(Nodes, Timeout, Timers) ->
    [N || N <- Nodes, has_timed_out(N, Timeout, Timers)].

active_nodes(Nodes, Timeout, Timers) ->
    [N || N <- Nodes, not has_timed_out(N, Timeout, Timers)].

timer_tree() ->
    gb_trees:empty().

get_timer(Item, Timers) ->
    gb_trees:get(Item, Timers).

add_timer(Item, ATime, TRef, Timers) ->
    TState = {ATime, TRef},
    gb_trees:insert(Item, TState, Timers).

del_timer(Item, Timers) ->
    {_, TRef} = get_timer(Item, Timers),
    _ = erlang:cancel_timer(TRef),
    gb_trees:delete(Item, Timers).

node_timer_from(Time, Timeout, {ID, IP, Port}) ->
    Msg = {inactive_node, ID, IP, Port},
    timer_from(Time, Timeout, Msg).

bucket_timer_from(Time, BTimeout, LeastRecent, NTimeout, Range) ->
    % In the best case, the bucket should time out N seconds
    % after the first node in the bucket timed out. If that node
    % can't be replaced, a bucket refresh should be performed
    % at most every N seconds, based on when the bucket was last
    % marked as active, instead of _constantly_.
    Msg = {inactive_bucket, Range},
    if
        LeastRecent <  Time ->
            timer_from(Time, BTimeout, Msg);
        LeastRecent >= Time ->
            SumTimeout = NTimeout + NTimeout,
            timer_from(LeastRecent, SumTimeout, Msg)
    end.


timer_from(Time, Timeout, Msg) ->
    Interval = ms_between(Time, Timeout),
    erlang:send_after(Interval, self(), Msg).

ms_since(Time) ->
    timer:now_diff(Time, now()) div 1000.

ms_between(Time, Timeout) ->
    MS = Timeout - ms_since(Time),
    if MS =< 0 -> Timeout;
       MS >= 0 -> MS
    end.

has_timed_out(Item, Timeout, Times) ->
    {LastActive, _} = get_timer(Item, Times),
    ms_since(LastActive) > Timeout.

least_recent([], _) ->
    now();
least_recent(Items, Times) ->
    ATimes = [element(1, get_timer(I, Times)) || I <- Items],
    lists:min(ATimes).
