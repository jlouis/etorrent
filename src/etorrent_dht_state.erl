-module(etorrent_dht_state).
-behaviour(gen_server).
-compile(export_all).
-import(ordsets, [add_element/2, del_element/2]).

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
         dump_state/0,
         dump_state/1,
         dump_state/3,
         load_state/1]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {
    node_id,
    buckets=b_new(),                  % The set used for the routing table
    node_timers=gb_trees:empty(),     % Timers used for node timeouts 
    node_access=gb_trees:empty(),     % Last time of node activity
    buck_timers=gb_trees:empty(),     % Timers used for bucket timeouts
    node_timeout=10*60*1000,          % Node keepalive timeout
    buck_timeout=5*60*1000,           % Bucket refresh timeout
    node_buffers=gb_trees:empty(),    % FIFO buckets for unmaintained nodes
    state_file="/tmp/dht_state"}).    % Path to persistent state
%
% Since each key in the node_access tree is always a
% member of the node set, use the node_access tree to check
% if a node is a member of the routing table.
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
ensure_bin_id(ID) when is_integer(ID) -> <<ID:160>>;
ensure_bin_id(ID) when is_binary(ID) -> ID.

ensure_int_id(ID) when is_binary(ID) -> <<IntID:160>> = ID, IntID;
ensure_int_id(ID) when is_integer(ID) -> ID.

srv_name() ->
    etorrent_dht_state_server.

start_link(StateFile) ->
    gen_server:start_link({local, srv_name()}, ?MODULE, [StateFile], []).

node_id() ->
    gen_server:call(srv_name(), {node_id}).

%
% Check if a node is available and lookup its node id by issuing
% a ping query to it first. This function must be used when we
% don't know the node id of a node.
%
safe_insert_node(IP, Port) ->
    case etorrent_dht_net:ping(IP, Port) of
        pang -> {error, timeout};
        ID   -> unsafe_insert_node(ID, IP, Port)
    end.

%
% Check if a node is available and verify its node id by issuing
% a ping query to it first. This function must be used when we
% want to verify the identify and status of a node.
%
safe_insert_node(ID, IP, Port) ->
    case is_interesting(ID, IP, Port) of
        false ->
            ok;
        true ->
            case etorrent_dht_net:ping(IP, Port) of
                pang -> ok;
                ID   -> unsafe_insert_node(ID, IP, Port);
                _    -> ok
        end
    end.

safe_insert_nodes(NodeInfos) ->
    [spawn_link(?MODULE, safe_insert_node, [ID, IP, Port])
    || {ID, IP, Port} <- NodeInfos].

%
% Blindly insert a node into the routing table. Use this function when
% inserting a node that was found and successfully queried in a find_node
% or get_peers search.
% 
% 
unsafe_insert_node(ID, IP, Port) ->
    gen_server:call(srv_name(), {insert_node, ID, IP, Port}).

unsafe_insert_nodes(NodeInfos) ->
    [spawn_link(?MODULE, unsafe_insert_node, [ID, IP, Port])
    || {ID, IP, Port} <- NodeInfos].

%
% Check if node would fit into the routing table. This
% function is used by the safe_insert_node(s) function
% to avoid issuing ping-queries to every node sending
% this node a query.
%
is_interesting(ID, IP, Port) ->
    gen_server:call(srv_name(), {is_interesting, ID, IP, Port}).


closest_to(NodeID) ->
    closest_to(NodeID, 8).

closest_to(NodeID, NumNodes) ->
    gen_server:call(srv_name(), {closest_to, NodeID, NumNodes}).

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
    {NodeID, NodeList} = load_state(StateFile),

    % Insert any nodes loaded from the persistent state later
    % when we are up and running. Use unsafe insertions or the
    % whole state will be lost if etorrent starts without 
    % internet connectivity.
    Later = fun() -> random:uniform(5000) end,
    [timer:apply_after(Later(), ?MODULE, unsafe_insert_node, [ensure_bin_id(ID), IP, Port])
    || {ID, IP, Port} <- NodeList],

    #state{
        buckets=Buckets,
        buck_timers=InitBTimers,
        buck_timeout=BTimeout} = #state{},
    [RootRange] = b_ranges(Buckets),
    BTimers = init_bucket_timer(RootRange, BTimeout, InitBTimers),

    State = #state{
        node_id=ensure_int_id(NodeID),
        buck_timers=BTimers,
        state_file=StateFile},
    {ok, State}.

handle_call({is_interesting, InputID, IP, Port}, _From, State) -> 
    ID = ensure_int_id(InputID),
    #state{
        buckets=Buckets,
        node_timeout=NTimeout,
        node_access=NAccess} = State,
    IsInteresting = case b_is_member(ID, IP, Port, Buckets) of
        false -> false;
        true ->
            BMembers = b_members(ID, Buckets),   
            DMembers = disconnected(BMembers, NTimeout, NAccess),
            DMembers =/= []
    end,
    {reply, IsInteresting, State};

handle_call({insert_node, InputID, IP, Port}, _From, State) ->
    ID = ensure_int_id(InputID),
    #state{
        node_id=Self,
        buckets=PrevBuckets,
        node_timers=PrevNTimers,
        node_access=PrevNAccess,
        buck_timers=PrevBTimers,
        node_timeout=NTimeout,
        buck_timeout=BTimeout} = State,

    IsPrevMember = b_is_member(ID, IP, Port, PrevBuckets),
    Disconnected = case IsPrevMember of
        true  -> [];
        false ->
            PrevBMembers = b_members(ID, PrevBuckets),
            disconnected(PrevBMembers, NTimeout, PrevNAccess)
    end,

    {NewBuckets, Deleted} = case {IsPrevMember, Disconnected} of
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
    {TmpNTimers, TmpNAccess} = case Deleted of
        none ->
            {PrevNTimers, PrevNAccess};
        {DID, DIP, DPort} ->
            {cancel_node_timer(DID, DIP, DPort, PrevNTimers),
             clear_node_access(DID, DIP, DPort, PrevNAccess)}
    end,



    IsNewMember = b_is_member(ID, IP, Port, NewBuckets),
    {NewNTimers, NewNAccess} = case {IsPrevMember, IsNewMember} of
        {false, false} ->
            {TmpNTimers, TmpNAccess};

        {true, true} ->
            {TmpNTimers, TmpNAccess};
        
        {false, true} ->
            {init_node_timer(ID, IP, Port, NTimeout, TmpNTimers),
             init_node_access(ID, IP, Port, TmpNAccess)}
    end,

    NewBTimers = case {IsPrevMember, IsNewMember} of
        {false, false} ->
            % No changes, the old node timers are still valid
            PrevBTimers;
        {true, true} ->
            PrevBTimers;

        {false, true} ->
            % The bucket set may have changed, The least recently active
            % node in the affected buckets may also have changed.
            % Reset all bucket timers to be sure.
            TmpBTimers = lists:foldl(fun(Range, Acc) ->
                cancel_bucket_timer(Range, Acc)
            end, PrevBTimers, b_ranges(PrevBuckets)),
            
            CaseBTimers = lists:foldl(fun(Range, Acc) ->
                TmpBMembers = b_members(Range, NewBuckets),
                LeastRecent = n_least_recent(TmpBMembers, NewNAccess),
                init_bucket_timer(Range, LeastRecent, BTimeout, Acc)
            end, TmpBTimers, b_ranges(NewBuckets)),
            CaseBTimers
    end, 
    B0 = lists:sort(gb_trees:keys(NewBTimers)),
    B1 = lists:sort(b_ranges(NewBuckets)),
    true = (B0 == B1),
    NewState = State#state{
        buckets=NewBuckets,
        node_timers=NewNTimers,
        node_access=NewNAccess,
        buck_timers=NewBTimers},
    {reply, ok, NewState};
            



handle_call({closest_to, InputNodeID, NumNodes}, From, State) ->
    NodeID = ensure_int_id(InputNodeID),
    #state{buckets=Buckets} = State,
    Nodes = b_node_list(Buckets),
    CloseNodes  = etorrent_dht:closest_to(NodeID, Nodes, NumNodes),
    OutputClose = [{Dist, ensure_bin_id(OID), OIP, OPort} || {Dist, OID, OIP, OPort} <- CloseNodes],
    {reply, OutputClose, State};


handle_call({request_timeout, InputID, IP, Port}, From, State) ->
    ID = ensure_int_id(InputID),
    #state{
        buckets=Buckets,
        node_timeout=NTimeout,
        node_timers=PrevNTimers,
        node_access=NAccess} = State,

    NewState = case b_is_member(ID, IP, Port, Buckets) of
        false ->
            State;
        true ->
            NewNTimers = reset_node_timer(ID, IP, Port, NTimeout, PrevNTimers),
            State#state{node_timers=NewNTimers}
    end,
    {reply, ok, NewState};

handle_call({request_success, InputID, IP, Port}, From, State) ->
    ID = ensure_int_id(InputID),
    #state{
        node_id=Self,
        buckets=Buckets,
        node_timeout=NTimeout,
        node_timers=PrevNTimers,
        node_access=PrevNAccess,
        buck_timers=PrevBTimers,
        buck_timeout=BTimeout} = State,
    NewState = case b_is_member(ID, IP, Port, Buckets) of
        false ->
            State;
        true ->
            NewNTimers  = reset_node_timer(ID, IP, Port, NTimeout, PrevNTimers),
            NewNAccess  = reset_node_access(ID, IP, Port, PrevNAccess),
            Bucket      = b_range(ID, Buckets),
            BMembers    = b_members(Bucket, Buckets),
            LeastRecent = n_least_recent(BMembers, NewNAccess),
            TmpBTimers  = cancel_bucket_timer(Bucket, PrevBTimers),
            NewBTimers  = init_bucket_timer(Bucket, LeastRecent, BTimeout, TmpBTimers),
            State#state{
                node_timers=NewNTimers,
                node_access=NewNAccess,
                buck_timers=NewBTimers}
    end,
    {reply, ok, NewState};


handle_call({request_from, ID, IP, Port}, From, State) ->
    {reply, ok, State};

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

handle_cast(_, State) ->
    {noreply, State}.

handle_info({inactive_node, InputID, IP, Port}, State) ->
    ID = ensure_int_id(InputID),
    #state{
        buckets=Buckets,
        node_timers=PrevNTimers,
        node_timeout=NTimeout} = State,
    NewState = case b_is_member(ID, IP, Port, Buckets) of
        false ->
            State;
        true ->
            error_logger:info_msg("Node at ~w:~w timed out", [IP, Port]),
            _ = spawn_link(?MODULE, keepalive, [ensure_bin_id(ID), IP, Port]),
            NewNTimers = reset_node_timer(ID, IP, Port, NTimeout, PrevNTimers),
            State#state{node_timers=NewNTimers}
    end,
    {noreply, NewState};

handle_info({inactive_bucket, Bucket}, State) ->
    #state{
        node_id=Self,
        buckets=Buckets,
        node_access=NAccess,
        node_timeout=NTimeout,
        buck_timers=PrevBTimers,
        buck_timeout=BTimeout} = State,

    NewState = case b_has_bucket(Bucket, Buckets) of
        false ->
            State;
        true ->
            TmpBTimers = cancel_bucket_timer(Bucket, PrevBTimers),
            NewBTimers = init_bucket_timer(Bucket, BTimeout, TmpBTimers),
            State#state{buck_timers=NewBTimers}
    end,
    {noreply, NewState}.

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

code_change(_, _, State) ->
    {ok, State}.


is_disconnected(ID, IP, Port, Timeout, AccessTimes) ->
    LastActive = gb_trees:get({ID, IP, Port}, AccessTimes),
    (timer:now_diff(LastActive, now()) div 1000) > Timeout.

disconnected(Nodes, Timeout, AccessTimes) ->
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

-define(K, 8). 
-define(in_range(IDExpr, MinExpr, MaxExpr),
    ((IDExpr >= MinExpr) and (IDExpr < MaxExpr))).

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
b_delete(ID, IP, Port, []) ->
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
b_is_member(ID, IP, Port, []) ->
    false;
b_is_member(ID, IP, Port, [{Min, Max, Members}|T])
when ?in_range(ID, Min, Max) ->
    lists:member({ID, IP, Port}, Members);
b_is_member(ID, IP, Port, [_|T]) ->
    b_is_member(ID, IP, Port, T).

%
% Check if a bucket exists in a bucket list
%
b_has_bucket({_, _}, []) ->
    false;
b_has_bucket({Min, Max}, [{Min, Max, _}|T]) ->
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
b_range(ID, [{Min, Max, _}|_])
when ?in_range(ID, Min, Max) ->
    {Min, Max};
b_range(ID, [_|T]) ->
    b_range(ID, T).



%
% Return the last time of activity of the least recently
% active node in the given node set. If the node set is
% empty, return the current time. This will cause it to back off.
%
n_least_recent([], _) ->
    now();
n_least_recent(Nodes, AccessTimes) ->
    lists:min([gb_trees:get({ID, IP, Port}, AccessTimes)
             ||{ID, IP, Port} <- Nodes]).


init_bucket_timer(Range, Timeout, Timers) ->
    Msg = {inactive_bucket, Range},
    Ref = erlang:send_after(Timeout, self(), Msg),
    gb_trees:insert(Range, Ref, Timers).

init_bucket_timer(Range, LastActive, BTimeout, Timers) ->
    MicroSince  = timer:now_diff(LastActive, now()),
    MilliSince  = MicroSince div 1000,
    NextTimeout = BTimeout - MilliSince,
    init_bucket_timer(Range, NextTimeout, Timers).

%
% Cancel the timer for a bucket, note that calling this function
% is by no means a guarantee that this timer has not already fired
% and left a message in our inbox already, don't trust it.
%
cancel_bucket_timer(Range, Timers) ->
    Ref = gb_trees:get(Range, Timers),
    erlang:cancel_timer(Ref),
    gb_trees:delete(Range, Timers).

%
% Calculate the time in milliseconds until when the timer for a bucket
% should fire. The return value is in milliseconds because that is what
% erlang:send_after/3 expects.
% 
next_bucket_timeout(LastActive, Timeout) ->
    Timeout - (timer:now_diff(LastActive, now()) div 1000).
