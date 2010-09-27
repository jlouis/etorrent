-module(etorrent_dht_state).
-behaviour(gen_server).

%
% This module implements a server maintaining the
% DHT routing table. The routing table is stored as
% an ordered set of ID, IP, Port triplets.
%
% A set of buckets, distance ranges, is used to limit
% the number of nodes in the routing table. The routing
% table must only contain 8 nodes that fall within the
% range of each bucket. A bucket is defined for the range
% (2^n) - 1 to 2^(n + 1) for each number between 0 and 161.
%
% Each bucket is maintaned independently. If there are four
% or more disconnected nodes in a bucket, the contents are
% refreshed by querying the remaining nodes in the bucket.
%
% A bucket is also refreshed once a disconnected node has
% been disconnected for 5 minutes. This ensures that buckets
% are not refreshed too frequently. 
%
% A node is considered disconnected if it does not respond to
% a ping query after 10 minutes of inactivity.
%
% A node is also considered disconnected if any query sent to
% it times out and a subsequent ping query also times out.
%
% To make sure that each node that is inserted into the
% routing table is reachable from this node a ping query
% is issued for each node before it replaces an existing
% node.
%


-export([srv_name/0,
         start_link/1,
         node_id/0,
         insert_node/2,
         insert_nodes/1,
         insert_node/3,
         closest_to/1,
         closest_to/2,
         get_peers/1,
         log_request_timeout/3,
         log_request_success/3,
         log_request_from/3,
         keepalive/3,
         dump_state/0,
         dump_state/1,
         dump_state/2,
         load_state/2]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {
    node_id,
    node_set=ordsets:new(),          % The set used for the routing table
    node_timers=gb_trees:empty(),    % Timers used for node timeouts 
    node_access=gb_trees:empty(),    % Last time of node activity
    buck_timers=gb_trees:empty(),    % Timers used for bucket timeouts
    node_timeout=10*60*1000,         % Node keepalive timeout
    buck_timeout=5*60*1000,          % Bucket refresh timeout
    node_buffers=gb_trees:empty()}). % FIFO buckets for unmaintained nodes
%
% Since each key in the node_access tree is always a
% member of the node set, use the node_access tree to check
% if a node is a member of the routing table.
%
% The bucket refresh timeout is the amount of time that the
% server will tolerate a node to be disconnected before it
% attempts to refresh the bucket.
%

srv_name() ->
    etorrent_dht_state_server.

start_link(StateFile) ->
    gen_server:start_link({local, srv_name()}, ?MODULE, [StateFile], []).

node_id() ->
    gen_server:call(srv_name(), {node_id}).

insert_node(IP, Port) ->
    case etorrent_dht_net:ping(IP, Port) of
        pang -> {error, timeout};
        ID   -> gen_server:call(srv_name(), {insert_node, ID, IP, Port})
    end.

insert_node(ID, IP, Port) ->
    Call = {insert_node, ID, IP, Port},
    case etorrent_dht_net:ping(IP, Port) of
        pang -> ok;
        ID   -> gen_server:call(srv_name(), Call);
        _    -> ok
    end.

insert_nodes(NodeInfos) ->
    gen_server:call(srv_name(), {insert_nodes, NodeInfos}).

closest_to(NodeID) ->
    closest_to(NodeID, 8).

closest_to(NodeID, NumNodes) ->
    gen_server:call(srv_name(), {closest_to, NodeID, NumNodes}).

get_peers(InfoHash) ->
    [].

log_request_timeout(ID, IP, Port) ->
    Call = {request_timeout, ID, IP, Port},
    gen_server:call(srv_name(), Call).

log_request_success(ID, IP, Port) ->
    Call = {request_success, ID, IP, Port},
    gen_server:call(srv_name(), Call).

log_request_from(ID, IP, Port) ->
    Call = {request_from, ID, IP, Port},
    gen_server:call(srv_name(), Call).

dump_state() ->
    gen_server:call(srv_name(), {dump_state}).

dump_state(Filename) ->
    gen_server:call(srv_name(), {dump_state, Filename}).

keepalive(ID, IP, Port) ->
    case etorrent_dht_net:ping(IP, Port) of
        ID    -> log_request_success(ID, IP, Port);
        pang  -> log_request_timeout(ID, IP, Port);
        _     -> log_request_timeout(ID, IP, Port)
    end.



init([StateFile]) ->
    InitState = load_state(StateFile, #state{}),
    #state{
        node_set=InitNodes,
        buck_timers=InitBTimers,
        node_timers=InitNTimers,
        node_access=InitNAccess} = InitState,

    % If any nodes are loaded on startup, access times and
    % timers must be restored to reasonably short values.
    BTimers = lists:foldl(fun(Bucket, Acc) ->
        init_bucket_timer(Bucket, 1000, Acc)
    end, InitBTimers, bucket_ranges()),

    NTimers = lists:foldl(fun({ID, IP, Port}, Acc) ->
        init_node_timer(ID, IP, Port, 1000, Acc)
    end, InitNTimers, InitNodes),

    NAccess = lists:foldl(fun({ID, IP, Port}, Acc) ->
        init_node_access(ID, IP, Port, Acc)
    end, InitNAccess, InitNodes),

    State = InitState#state{
        buck_timers=BTimers,
        node_timers=NTimers,
        node_access=NAccess},
    {ok, State}.

handle_call({insert_nodes, Nodes}, From, State) ->
     
    #state{
        node_id=Self,
        node_set=PrevNodes,
        node_timers=PrevNTimers,
        node_access=PrevNAccess,
        buck_timers=PrevBTimers,
        node_timeout=NTimeout,
        buck_timeout=BucketTimeout} = State,

    % Don't consider nodes that are already present in the routing table 
    InsNodes = [N || {ID, IP, Port}=N <- Nodes,
               not is_in_table(ID, IP, Port, PrevNTimers)],

    % These nodes will be distributed across a set of buckets
    Ranges  = bucket_ranges(),
    Buckets = ordsets:from_list(
        [bucket_range(etorrent_dht:distance(ID, Self), Ranges) || {ID, _, _} <- InsNodes]),

    _ = [begin
        % Which nodes are already in this bucket, and which
        % new nodes should be inserted into this bucket?
        BMembers = bucket_nodes(Self, Bucket, PrevNodes),
        Inserted = bucket_nodes(Self, Bucket, InsNodes),

        % Find all nodes that are considered disconnected in this
        % bucket and spawn a process to check/insert at most 8
        % of the new nodes to replace them.
        InActive = disconnected_nodes(BMembers, NTimeout, PrevNAccess),
        _ = case InActive of
            [] when length(BMembers) == 8 -> ok;
            _  ->
                [spawn_link(?MODULE, insert_node, [ID, IP, Port])
                || {ID, IP, Port} <- Inserted]
        end
    end || Bucket  <- Buckets],

    {reply, ok, State};

%
% Insert one node into the routing table if any nodes that
% the node it is replacing still exists in the bucket the node 
% would be placed in.
%
handle_call({insert_node, ID, IP, Port}, From, State) ->
    #state{
        node_id=Self,
        node_set=PrevNodes,
        node_timers=PrevNTimers,
        node_access=PrevNAccess,
        buck_timers=PrevBTimers,
        node_timeout=NTimeout,
        buck_timeout=BTimeout} = State,
    
    Bucket       = bucket_range(Self, ID, bucket_ranges()),
    PrevBMembers = bucket_nodes(Self, Bucket, PrevNodes),
    Disconn      = disconnected_nodes(PrevBMembers, NTimeout, PrevNAccess),
    IsMember     = is_in_table(ID, IP, Port, PrevNAccess),

    NewState = case {IsMember, Disconn} of
        {true, _} ->
            State;

        {false, []} when length(PrevBMembers) >= 8 ->
            State;       

        {false, []} when length(PrevBMembers) < 8 ->
            error_logger:info_msg("Inserting ~w:~w into the routing table", [IP, Port]),
            New = {ID, IP, Port},
            NewNodes   = ordsets:add_element(New, PrevNodes),
            NewNTimers = init_node_timer(ID, IP, Port, NTimeout, PrevNTimers),
            NewNAccess = init_node_access(ID, IP, Port, PrevNAccess),
            BMembers   = bucket_nodes(Self, Bucket, NewNodes),
            NewBTimers = reset_bucket_timer(Bucket, BTimeout, BMembers, NewNAccess, PrevBTimers),

            State#state{
                node_set=NewNodes,
                node_timers=NewNTimers,
                node_access=NewNAccess,
                buck_timers=NewBTimers};

        {false, [{OldID, OldIP, OldPort}=Old|_]} ->
            New = {ID, IP, Port},

            NWithout = ordsets:del_element(Old, PrevNodes),
            NewNodes = ordsets:add_element(New, NWithout),
           
            NTWithout  = cancel_node_timer(OldID, OldIP, OldPort, PrevNTimers),
            NewNTimers = init_node_timer(ID, IP, Port, NTimeout, NTWithout),

            NAWithout  = clear_node_access(OldID, OldIP, OldPort, PrevNAccess),
            NewNAccess = init_node_access(ID, IP, Port, NAWithout),

            BMembers = bucket_nodes(Self, Bucket, NewNodes),
            NewBTimers = reset_bucket_timer(Bucket, BTimeout, BMembers, NewNAccess, PrevBTimers),

            State#state{
                node_set=NewNodes,
                node_timers=NewNTimers,
                node_access=NewNAccess,
                buck_timers=NewBTimers}
    end,
    {reply, ok, NewState};
            



handle_call({closest_to, NodeID, NumNodes}, From, State) ->
    #state{node_set=Nodes} = State,
    CloseNodes = etorrent_dht:closest_to(NodeID, Nodes, NumNodes),
    {reply, CloseNodes, State};


handle_call({request_timeout, ID, IP, Port}, From, State) ->
    #state{
        node_timeout=NTimeout,
        node_timers=PrevNTimers,
        node_access=NodeAccess} = State,

    NewState = case is_in_table(ID, IP, Port, NodeAccess) of
        false ->
            State;
        true ->
            NewNTimers = reset_node_timer(ID, IP, Port, NTimeout, PrevNTimers),
            State#state{node_timers=NewNTimers}
    end,
    {reply, ok, State};

handle_call({request_success, ID, IP, Port}, From, State) ->
    #state{
        node_id=Self,
        node_set=Nodes,
        node_timeout=NTimeout,
        node_timers=PrevNTimers,
        node_access=PrevNAccess,
        buck_timers=PrevBTimers,
        buck_timeout=BTimeout} = State,
    NewState = case is_in_table(ID, IP, Port, PrevNAccess) of
        false ->
            State;
        true ->
            NewNTimers = reset_node_timer(ID, IP, Port, NTimeout, PrevNTimers),
            NewNAccess = reset_node_access(ID, IP, Port, PrevNAccess),
            Bucket     = bucket_range(Self, ID, bucket_ranges()),
            BMembers   = bucket_nodes(Self, Bucket, Nodes),
            NewBTimers = reset_bucket_timer(Bucket, BTimeout, BMembers, NewNAccess, PrevBTimers),
            State#state{
                node_timers=NewNTimers,
                node_access=NewNAccess,
                buck_timers=NewBTimers}
    end,
    {reply, ok, NewState};


handle_call({request_from, ID, IP, Port}, From, State) ->
    {reply, ok, State};

handle_call({dump_state}, _From, State) ->
    {reply, State, State};

handle_call({dump_state, Filename}, _From, State) ->
   catch dump_state(Filename, State),
    {reply, ok, State};

handle_call({node_id}, _From, State) ->
    #state{node_id=Self} = State,
    {reply, Self, State}.

handle_cast(_, State) ->
    {noreply, State}.

handle_info({inactive_node, ID, IP, Port}, State) ->
    #state{
        node_access=NAccess,
        node_timers=PrevNTimers,
        node_timeout=NTimeout} = State,
    NewState = case is_in_table(ID, IP, Port, NAccess) of
        false -> State;
        true ->
            error_logger:info_msg("Node at ~w:~w timed out", [IP, Port]),
            _ = spawn_link(?MODULE, keepalive, [ID, IP, Port]),
            NewNTimers = reset_node_timer(ID, IP, Port, NTimeout, PrevNTimers),
            State#state{node_timers=NewNTimers}
    end,
    {noreply, NewState};

handle_info({inactive_bucket, Bucket}, State) ->
    #state{
        node_id=Self,
        node_set=Nodes,
        node_access=NAccess,
        node_timeout=NTimeout,
        buck_timers=PrevBTimers,
        buck_timeout=BTimeout} = State,

    BMembers   = bucket_nodes(Self, Bucket, Nodes),
    TmpBTimers = cancel_bucket_timer(Bucket, PrevBTimers),
    NewBTimers = init_bucket_timer(Bucket, BTimeout, TmpBTimers),
    NewState   = State#state{buck_timers=NewBTimers},

    {noreply, NewState}.

terminate(_, State) ->
    dump_state("etorrent_dht.persistent", State).

dump_state(Filename, ServerState) ->
    #state{
        node_id=Self,
        node_set=Nodes} = ServerState,
    PersistentState = [{node_id, Self}, {node_set, Nodes}],
    file:write_file(Filename, term_to_binary(PersistentState)).

load_state(Filename, ServerState) ->
    case file:read_file(Filename) of
        {ok, BinState} ->
            PersistentState = binary_to_term(BinState),
            {value, {_, Self}}  = lists:keysearch(node_id, 1, PersistentState),
            {value, {_, Nodes}} = lists:keysearch(node_set, 1, PersistentState),
            ServerState#state{
                node_id=Self,
                node_set=Nodes};
        {error, Reason} ->
            error_logger:error_msg("Failed to load state from ~s", [Filename]),
            ServerState#state{
                node_id=etorrent_dht:random_id()}
    end.

code_change(_, _, State) ->
    {ok, State}.


is_in_table(ID, IP, Port, AccessTimes) ->
    gb_trees:is_defined({ID, IP, Port}, AccessTimes).

is_disconnected(ID, IP, Port, Timeout, AccessTimes) ->
    LastActive = gb_trees:get({ID, IP, Port}, AccessTimes),
    (timer:now_diff(LastActive, now()) div 1000) > Timeout.

disconnected_nodes(Nodes, Timeout, AccessTimes) ->
    [N || {ID, IP, Port}=N <- Nodes,
    is_disconnected(ID, IP, Port, Timeout, AccessTimes)].

nodes_by_access(Nodes, AccessTimes) ->
    GetTime  = fun({_, _, _}=N) -> gb_trees:get(N, AccessTimes) end,
    WithTime = [{GetTime(N), ID, IP, Port} || {ID, IP, Port}=N <- Nodes],
    ByTime   = lists:sort(WithTime),
    [{ID, IP, Port} || {_, ID, IP, Port} <- ByTime].


reset_node_timer(ID, IP, Port, Timeout, Timers) ->
    init_node_timer(ID, IP, Port, Timeout,
        cancel_node_timer(ID, IP, Port, Timers)).

init_node_timer(ID, IP, Port, Timeout, Timers) -> 
    Msg = {inactive_node, ID, IP, Port},
    Ref = erlang:send_after(Timeout, self(), Msg),
    gb_trees:insert({ID, IP, Port}, Ref, Timers).

cancel_node_timer(ID, IP, Port, Timers) ->
    Ref = gb_trees:get({ID, IP, Port}, Timers),
    erlang:cancel_timer(Ref),
    gb_trees:delete({ID, IP, Port}, Timers).

reset_node_access(ID, IP, Port, Access) ->
    init_node_access(ID, IP, Port,
        clear_node_access(ID, IP, Port, Access)).

init_node_access(ID, IP, Port, Access) ->
    gb_trees:insert({ID, IP, Port}, now(), Access).

clear_node_access(ID, IP, Port, Access) ->
    gb_trees:delete({ID, IP, Port}, Access).



%
% Return an ordered set of all bucket ranges
%
bucket_ranges() ->
    UpperLimits = [trunc(math:pow(2, N))     || N <- lists:seq(1, 161)],
    LowerLimits = [trunc(math:pow(2, N)) - 1 || N <- lists:seq(0, 160)],
    BucketList  = lists:zip(LowerLimits, UpperLimits).

%
% Determine which bucket range a distance falls within
%    
bucket_range(Distance, [{Min, Max}|T])
when Distance >= Min, Distance =< Max ->
    {Min, Max};
bucket_range(Distance, [_|T]) ->
    bucket_range(Distance, T).

%
% Determine which bucket range a node falls within
%
bucket_range(Self, ID, Ranges) ->
    Distance = etorrent_dht:distance(Self, ID),
    bucket_range(Distance, Ranges).


%
% Filter out all members of a bucket from a set of nodes
%
bucket_nodes(_, _, []) ->
    [];
bucket_nodes(Self, {Min, Max}=Bucket, [{ID, _, _}=H|T]) ->
    Dist = etorrent_dht:distance(ID, Self),
    if  (Dist >= Min) and (Dist =< Max) -> [H|bucket_nodes(Self, Bucket, T)];
        true -> bucket_nodes(Self, Bucket, T)
    end.

%
% Reset the timer for this bucket. This function should be ran each time
% the contents of a bucket is updated or the access times for a node
% in this bucket is updated.
%    
reset_bucket_timer(Bucket, Timeout, Members, NodeAccess, Timers) ->
    Without = cancel_bucket_timer(Bucket, Timers),
    init_bucket_timer(Bucket, Timeout, Members, NodeAccess, Without).

%
% Initialize a new timer for this bucket. The timer must fire 15 minutes
% after the least recently active member of bucket was active. If the bucket
% is empty, don't take any measures to populate it yet.
%
init_bucket_timer(Bucket, Timeout, Members, NodeAccess, Timers) ->
    ByAccess = nodes_by_access(Members, NodeAccess),
    NextTimeout = case ByAccess of
        [] -> Timeout;
        [{ID, IP, Port}|_] ->
           LastActive = gb_trees:get({ID, IP, Port}, NodeAccess),
           next_bucket_timeout(LastActive, Timeout)
    end,
    init_bucket_timer(Bucket, NextTimeout, Timers).

init_bucket_timer(Bucket, Timeout, Timers) ->
    Msg = {inactive_bucket, Bucket},
    Ref = erlang:send_after(Timeout, self(), Msg),
    gb_trees:insert(Bucket, Ref, Timers).

%
% Cancel the timer for a bucket, note that calling this function
% is by no means a guarantee that this timer has not already fired
% and left a message in our inbox already, don't trust it.
%
cancel_bucket_timer(Bucket, Timers) ->
    Ref = gb_trees:get(Bucket, Timers),
    erlang:cancel_timer(Ref),
    gb_trees:delete(Bucket, Timers).

%
% Calculate the time in milliseconds until when the timer for a bucket
% should fire. The return value is in milliseconds because that is what
% erlang:send_after/3 expects.
% 
next_bucket_timeout(LastActive, Timeout) ->
    Timeout - (timer:now_diff(LastActive, now()) div 1000).
