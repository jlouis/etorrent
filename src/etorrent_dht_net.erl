-module(etorrent_dht_net).
-include_lib("stdlib/include/qlc.hrl").
-behaviour(gen_server).
-import(etorrent_bcoding, [search_dict/2, search_dict_default/3]).
-define(is_infohash(Parameter),
    (is_binary(Parameter) and (byte_size(Parameter) == 20))).

%
% Implementation notes
%     RPC calls to remote nodes in the DHT are exposed to
%     clients using the gen_server call mechanism. In order
%     to make this work the client reference passed to the
%     handle_call/3 callback is stored in the server state.
%
%     When a response is received from the remote node, the
%     source IP and port combined with the message id is used
%     to map the response to the correct client reference.
%
%     A timer is used to notify the server of requests that
%     time out, if a request times out {error, timeout} is
%     returned to the client. If a response is received after
%     the timer has fired, the response is dropped.
%
%     The expected behavior is that the high-level timeout fires
%     before the gen_server call times out, therefore this interval
%     should be shorter then the interval used by gen_server calls.
%
%     The find_node_search/1 and get_peers_search/1 functions
%     are almost identical, they both recursively search for the
%     nodes closest to an id. The difference is that get_peers should
%     return as soon as it finds a node that acts as a tracker for
%     the infohash.

% Public interface
-export([start_link/0,
         node_id/0,
         ping/2,
         find_node/3,
         find_node_search/1,
         get_peers/3,
         get_peers_search/1,
         announce/5,
         return/4,

         bootstrap/2]).

% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

% internal exports
-export([handle_query/6]).


-record(state, {
    socket,
    sent,
    self
}).

%
% Type definitions and function specifications
%
-type ipaddr()  :: {0..255, 0..255, 0..255, 0..255}.
-type portnum() :: integer().

-spec ping(ipaddr(), portnum()) -> binary() | 'pang'.
-spec find_node(ipaddr(), portnum(), binary()) -> {'error', 'timeout'}.


%
% Contansts and settings
%
srv_name() ->
   dht_socket_server.

query_timeout() ->
    2000.

search_width() ->
    32.

search_retries() ->
    4.

socket_options() ->
    [list, inet, {active, true}].

any_port() ->
    0.

%
% Public interface
%
start_link() ->
    etorrent_dht_state:open(),
    gen_server:start({local, srv_name()}, ?MODULE, [], []).

node_id() ->
    gen_server:call(srv_name(), {get_node_id}).

%
%
%
ping(IP, Port) ->
    case gen_server:call(srv_name(), {ping, IP, Port}) of
        timeout -> pang;
        Reply   ->
            {string, ID} = search_dict({string, "id"}, Reply),
            list_to_binary(ID)
    end.

%
%
%
find_node(IP, Port, Target) when ?is_infohash(Target) ->
    case gen_server:call(srv_name(), {find_node, IP, Port, Target}) of
        timeout -> {error, timeout};
        Values  ->
            {string, ID} = search_dict({string, "id"}, Values),
            {string, Compact} = search_dict({string, "nodes"}, Values),
            BinCompact = list_to_binary(Compact),
            Nodes = compact_to_node_infos(BinCompact),
            {list_to_binary(ID), Nodes}
    end.

%
% Recursively search for the 100 nodes that are the closest to
% the local DHT node.
%
% Keep tabs on:
%     - Which nodes has been queried?
%     - Which nodes has responded?
%     - Which nodes has not been queried?
find_node_search(Target) when ?is_infohash(Target) ->
    Width = search_width(),
    Known = etorrent_dht_state:known_nodes(),
    Next = closest_to(Target, Known, Width),
    Queried = gb_sets:empty(),
    Alive = gb_sets:empty(),
    Retries = 0,
    MaxRetries = search_retries(),
    find_node_search(Target, Next, Queried, Alive,
                     Retries, MaxRetries, Width).


find_node_search(_Target, _Next, _Queried, Alive,
                 _MaxRetries, _MaxRetries, _Width) ->
    lists:sort(gb_sets:to_list(Alive));

find_node_search(Target, Next, Queried, Alive,
                 Retries, MaxRetries, Width) ->

    % Mark all nodes in the queue as queried
    AddQueried = [{ID, IP, Port} || {_, ID, IP, Port} <- Next],
    NewQueried = gb_sets:union(Queried, gb_sets:from_list(AddQueried)),

    % Query all nodes in the queue and generate a list of
    % {Dist, ID, IP, Port, Nodes} elements
    SearchCalls = [{?MODULE, find_node, [IP, Port, Target]}
                  || {_Dist, _ID, IP, Port} <- Next],
    ReturnValues = rpc:parallel_eval(SearchCalls),
    WithArgs = lists:zip(Next, ReturnValues),

    Successful = [{Dist, ID, IP, Port, Nodes}
                 ||{{Dist, ID, IP, Port},
                    {NID, Nodes}} <- WithArgs, is_binary(NID)],

    % Mark all nodes that responded as alive
    AddAlive = [{Dist, ID, IP, Port}
               ||{Dist, ID, IP, Port, _} <- Successful],
    NewAlive = gb_sets:union(Alive, gb_sets:from_list(AddAlive)),

    % Accumulate all nodes from the successful responses.
    % Calculate the relative distance to all of these nodes
    % and keep the closest nodes which has not already been
    % queried in a previous iteration
    NodeLists = [Nodes || {_, _, _, _, Nodes} <- Successful],
    AllNodes  = lists:flatten(NodeLists),

    NewNodes  = [NodeInfo
                || NodeInfo <- AllNodes
                ,  not gb_sets:is_member(NodeInfo, NewQueried)],
    NewNext = closest_to(Target, NewNodes, Width),

    % Check if the closest node in the work queue is closer
    % to the infohash than the closest responsive node.
    {MinAliveDist, _, _, _} = gb_sets:smallest(NewAlive),
    MinQueueDist = case NewNext of
        [] ->
            2 * MinAliveDist;
        Other ->
            {MinDist, _, _, _} = lists:min(Other),
            MinDist
    end,

    % Check if the closest node in the work queue is closer
    % to the infohash than the closest responsive node.
    NewRetries = if
        (MinQueueDist <  MinAliveDist) -> 0;
        (MinQueueDist >= MinAliveDist) -> Retries + 1 end,

    find_node_search(Target, NewNext, NewQueried, NewAlive,
                     NewRetries, MaxRetries, Width).


get_peers(IP, Port, InfoHash) when ?is_infohash(InfoHash) ->
    case gen_server:call(srv_name(), {get_peers, IP, Port, InfoHash}) of
        timeout -> {error, timeout};
        Values  ->
            {string, ID} = search_dict({string, "id"}, Values),
            {string, Token}  = search_dict({string, "token"}, Values),
            NoPeers = make_ref(),
            MaybePeers = search_dict_default({string, "values"},
                                           Values, NoPeers),
            {Peers, Nodes} = case MaybePeers of
                NoPeers ->
                    {string, LCompact} = search_dict({string, "nodes"}, Values),
                    Compact = list_to_binary(LCompact),
                    INodes = compact_to_node_infos(Compact),
                    {[], INodes};
                {list, PeerStrings} ->
                    BinPeers = [list_to_binary(S)
                               || {string, S} <- PeerStrings],
                    PeerLists = [compact_to_peers(N) || N <- BinPeers],
                    IPeers = lists:flatten(PeerLists),
                    {IPeers, []}
            end,
            {list_to_binary(ID), list_to_binary(Token), Peers, Nodes}
    end.

%
% Search the DHT for the node closest to the info-hash,
%
get_peers_search(InfoHash) when ?is_infohash(InfoHash) ->
    Width    = search_width(),
    MaxRetry = search_retries(),
    Known    = etorrent_dht_state:known_nodes(),
    Queue    = closest_to(InfoHash, Known, Width),
    Queried  = gb_sets:empty(),
    Alive    = gb_sets:empty(),
    Retries  = 0,
    get_peers_search(InfoHash, Queue, Queried, Alive,
                     Retries, MaxRetry, Width).


%% Retries twice???
get_peers_search(_InfoHash, _Queue, _Queried, Alive, _Retries, _Retries, _Width) ->
    % If the search has failed to come up with a node that is
    % closer to the infohash multiple times return a list of the
    % nodes closest to the infohash.
    {closest, lists:sort(gb_sets:to_list(Alive))};

get_peers_search(InfoHash, Queue, Queried, Alive,
              Retries, MaxRetries, Width) ->
    % Mark all nodes in the queue as queried
    AddQueried = [{ID, IP, Port} || {_, ID, IP, Port} <- Queue],
    NewQueried = gb_sets:union(Queried, gb_sets:from_list(AddQueried)),

    % Query all nodes in the queue and generate a list of
    % {Dist, ID, IP, Port, Peers, Nodes} elements
    SearchCalls = [{?MODULE, get_peers, [IP, Port, InfoHash]}
                  || {_Dist, _ID, IP, Port} <- Queue],
    ReturnValues = rpc:parallel_eval(SearchCalls),
    WithArgs = lists:zip(Queue, ReturnValues),

    Successful = [{Dist, ID, IP, Port, Peers, Nodes}
                 || {{Dist, ID, IP, Port},
                     {_, _, Peers, Nodes}} <- WithArgs],

    % Mark all nodes that responded as alive
    AddAlive = [{Dist, ID, IP, Port}
               ||{Dist, ID, IP, Port, _, _} <- Successful],
    NewAlive = gb_sets:union(Alive, gb_sets:from_list(AddAlive)),

    % Filter out results containing a non-empty list of peers
    % Omit the Nodes column because it has no meaning in this context
    HasPeers = [{Dist, ID, IP, Port, Peers}
              ||{Dist, ID, IP, Port, Peers, _} <- Successful
              , length(Peers) > 0],

    % Accumulate all nodes from the successful responses.
    % Calculate the relative distance to all of these nodes
    % and keep the closest nodes which has not already been
    % queried in a previous iteration
    NodeLists = [Nodes || {_, _, _, _, _, Nodes} <- Successful],
    AllNodes  = lists:flatten(NodeLists),

    IsQueried = fun(N) -> gb_sets:is_member(N, NewQueried) end,
    NewNodes  = [NodeInfo
                || NodeInfo <- AllNodes
                ,  not IsQueried(NodeInfo)],
    NewQueue  = closest_to(InfoHash, NewNodes, Width),

    % Check if the closest node in the work queue is closer
    % to the infohash than the closest responsive node.
    {MinAliveDist, _, _, _} = gb_sets:smallest(NewAlive),
    {MinQueueDist, _, _, _} = lists:min(NewQueue),
    NewRetries = if
        (MinQueueDist <  MinAliveDist) -> 0;
        (MinQueueDist >= MinAliveDist) -> Retries + 1 end,
    if
    (length(HasPeers) > 0) ->
        {found_tracker, HasPeers};
    (length(NewQueue) == 0) ->
        {error, queue_empty};
    (length(NewQueue) >  0) ->
        get_peers_search(InfoHash, NewQueue, NewQueried,
                         NewAlive, NewRetries, MaxRetries, Width)
    end.




%
%
%
announce(IP, Port, InfoHash, Token, BTPort) when ?is_infohash(InfoHash),
                                                 is_binary(Token),
                                                 is_integer(BTPort) ->
    Announce = {announce, IP, Port, InfoHash, Token, BTPort},
    case gen_server:call(srv_name(), Announce) of
        timeout -> {error, timeout};
        Reply   ->
            {string, ID} = search_dict({string, "id"}, Reply),
            list_to_binary(ID)
    end.

%
%
%
return(IP, Port, ID, Response) ->
    ok = gen_server:call(srv_name(), {return, IP, Port, ID, Response}).

%
% Bootstrap the local routing table using a known node
% This will clear the local routing table of all previous
% entries.
%
bootstrap(IP, Port) ->
    ok = etorrent_dht_state:clear(),
    {_, InitSet} = find_node(IP, Port, node_id()),
    ok = etorrent_dht_state:save(InitSet),
    NodeSet = find_node_search(node_id()),
    Entries = [{ID, Ip, P} || {_, ID, Ip, P} <- NodeSet],
    etorrent_dht_state:save(Entries).

init([]) ->
    ok = etorrent_dht_state:open(),
    {ok, Socket} = gen_udp:open(any_port(), socket_options()),
    State = #state{socket=Socket,
                   self=random_id(),
                   sent=gb_trees:empty()},
    {ok, State}.

closest_to(InfoHash, NodeList, NumNodes) ->
    WithDist = [{distance(ID, InfoHash), ID, IP, Port}
               || {ID, IP, Port} <- NodeList],
    Sorted = lists:sort(WithDist),
    if
    (length(Sorted) =< NumNodes) -> Sorted;
    (length(Sorted) >  NumNodes)  ->
        {Head, _Tail} = lists:split(NumNodes, Sorted),
        Head
    end.


timeout_reference(IP, Port, ID) ->
    Msg = {timeout, self(), IP, Port, ID},
    erlang:send_after(query_timeout(), self(), Msg).

cancel_timeout(TimeoutRef) ->
    erlang:cancel_timer(TimeoutRef).

handle_call({ping, IP, Port}, From, State) ->
    #state{self=Self} = State,
    LSelf = binary_to_list(Self),
    Args = [{{string, "id"}, {string, LSelf}}],
    do_send_query('ping', Args, IP, Port, From, State);

handle_call({find_node, IP, Port, Target}, From, State) ->
    #state{self=Self} = State,
    LSelf = binary_to_list(Self),
    LTarget = binary_to_list(Target),
    Args = [{{string, "id"}, {string, LSelf}},
            {{string, "target"}, {string, LTarget}}],
    do_send_query('find_node', Args, IP, Port, From, State);

handle_call({get_peers, IP, Port, InfoHash}, From, State) ->
    #state{self=Self} = State,
    LSelf = binary_to_list(Self),
    LHash = binary_to_list(InfoHash),
    Args = [{{string, "id"}, {string, LSelf}},
            {{string, "info_hash"}, {string, LHash}}],
    do_send_query('get_peers', Args, IP, Port, From, State);

handle_call({announce, IP, Port, InfoHash, Token, BTPort}, From, State) ->
    #state{self=Self} = State,
    LSelf = binary_to_list(Self),
    LHash = binary_to_list(InfoHash),
    LToken = binary_to_list(Token),
    Args = [{{string, "id"}, {string, LSelf}},
            {{string, "info_hash"}, {string, LHash}},
            {{string, "port"}, {integer, BTPort}},
            {{string, "token"}, {string, LToken}}],
    do_send_query('announce', Args, IP, Port, From, State);

handle_call({return, IP, Port, ID, Values}, _From, State) ->
    Socket = State#state.socket,
    Response = encode_response(ID, Values),
    ok = gen_udp:send(Socket, IP, Port, Response),
    {reply, ok, State};

handle_call({get_node_id}, _From, State) ->
    #state{self=Self} = State,
    {reply, Self, State};

handle_call({get_num_open}, _From, State) ->
    Sent = State#state.sent,
    NumSent = gen_trees:size(Sent),
    {reply, NumSent, State}.

do_send_query(Method, Args, IP, Port, From, State) ->
    #state{sent=Sent,
           socket=Socket} = State,

    MsgID = unique_message_id(IP, Port, Sent),
    Query = encode_query(Method, MsgID, Args),

    ok = gen_udp:send(Socket, IP, Port, Query),
    TRef = timeout_reference(IP, Port, MsgID),

    NewSent = store_sent_query(IP, Port, MsgID, From, TRef, Sent),
    NewState = State#state{sent=NewSent},
    {noreply, NewState}.

handle_cast(not_implemented, State) ->
    {noreply, State}.

handle_info({timeout, _, IP, Port, ID}, State) ->
    #state{sent=Sent} = State,

    NewState = case find_sent_query(IP, Port, ID, Sent) of
        error ->
            State;
        {ok, {Client, _Timeout}} ->
            _ = gen_server:reply(Client, timeout),
            NewSent = clear_sent_query(IP, Port, ID, Sent),
            State#state{sent=NewSent}
    end,
    {noreply, NewState};

handle_info({udp, _Socket, IP, Port, Packet}, State) ->
    Sent = State#state.sent,
    Self = State#state.self,
    NewState = case decode_msg(Packet) of
        {response, ID, Values} ->
            case find_sent_query(IP, Port, ID, Sent) of
                error ->
                    State;
                {ok, {Client, Timeout}} ->
                    _ = cancel_timeout(Timeout),
                    _ = gen_server:reply(Client, Values),
                    NewSent = clear_sent_query(IP, Port, ID, Sent),
                    State#state{sent=NewSent}
            end;
        {Method, ID, Params} ->
            HandlerArgs = [Method, Params, IP, Port, ID, Self],
            spawn_link(?MODULE, handle_query, HandlerArgs),
            State
    end,
    {noreply, NewState};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_, State) ->
    catch gen_udp:close(State#state.socket),
    catch etorrent_dht_state:close(),
    {ok, State}.

code_change(_, _, State) ->
    {ok, State}.

node_id_param(Params) ->
    {string, LNodeID} = search_dict({string, "id"}, Params),
    list_to_binary(LNodeID).

common_values(Self) ->
    [{{string, "id"}, {string, binary_to_list(Self)}}].

handle_query('ping', Params, IP, Port, MsgID, Self) ->
    _NodeID = node_id_param(Params),
    return(IP, Port, MsgID, common_values(Self));

handle_query('find_node', Params, IP, Port, MsgID, Self) ->
    _NodeID = node_id_param(Params),
    {string, LTarget} = search_dict({string, "target"}, Params),
    Target = list_to_binary(LTarget),
    CloseNodes = etorrent_dht_state:closest_to(Target),
    BinCompact = node_infos_to_compact(CloseNodes),
    LCompact = binary_to_list(BinCompact),
    Values = [{{string, "nodes"}, {string, LCompact}}],
    return(IP, Port, MsgID, common_values(Self) ++ Values);

handle_query('get_peers', Params, IP, Port, MsgID, Self) ->
    _NodeID = node_id_param(Params),
    {string, LHash} = search_dict({string, "info_hash"}, Params),
    InfoHash = list_to_binary(LHash),
    Values = case etorrent_dht_state:get_peers(InfoHash) of
        [] ->
            Nodes = etorrent_dht_state:closest_to(InfoHash),
            BinCompact = node_infos_to_compact(Nodes),
            LCompact = binary_to_list(BinCompact),
            [{{string, "nodes"}, {string, LCompact}}];
        Peers ->
            BinCompact = peers_to_compact(Peers),
            LCompact = binary_to_list(BinCompact),
            [{{string, "peers"}, {string, LCompact}}]
    end,
    return(IP, Port, MsgID, common_values(Self) ++ Values).


unique_message_id(IP, Port, Open) ->
    IntID = random:uniform(16#FFFF),
    MsgID = <<IntID:16>>,
    IsLocal  = gb_trees:is_defined(tkey(IP, Port, MsgID), Open),
    if IsLocal -> unique_message_id(IP, Port, Open);
       true    -> MsgID
    end.

store_sent_query(IP, Port, ID, Client, Timeout, Open) ->
    K = tkey(IP, Port, ID),
    V = tval(Client, Timeout),
    gb_trees:insert(K, V, Open).

find_sent_query(IP, Port, ID, Open) ->
    case gb_trees:lookup(tkey(IP, Port, ID), Open) of
       none -> error;
       {value, Value} -> {ok, Value}
    end.

clear_sent_query(IP, Port, ID, Open) ->
    gb_trees:delete(tkey(IP, Port, ID), Open).

tkey(IP, Port, ID) ->
   {IP, Port, ID}.

tval(Client, TimeoutRef) ->
    {Client, TimeoutRef}.

random_id() ->
    Byte  = fun() -> random:uniform(256) - 1 end,
    Bytes = [Byte() || _ <- lists:seq(1, 20)],
    list_to_binary(Bytes).


distance(BID0, BID1) ->
    <<ID0:160>> = BID0,
    <<ID1:160>> = BID1,
    ID0 bxor ID1.

decode_msg(InMsg) ->
    Msg = etorrent_bcoding:decode(InMsg),
    {string, SMsgID} = search_dict({string, "t"}, Msg),
    MsgID = list_to_binary(SMsgID),
    case search_dict({string, "y"}, Msg) of
        {string, "q"} ->
            {string, MString} = search_dict({string, "q"}, Msg),
            {dict, Params}    = search_dict({string, "a"}, Msg),
            Method  = string_to_method(MString),
            {Method, MsgID, {dict, Params}};
        {string, "r"} ->
            {dict, Values} = search_dict({string, "r"}, Msg),
            {response, MsgID, {dict, Values}};
        {string, "e"} ->
            error
    end.


encode_query(Method, MsgID, Params) ->
    Msg = {dict, [
              {{string, "y"}, {string, "q"}},
              {{string, "q"}, {string, method_to_string(Method)}},
              {{string, "t"}, {string, binary_to_list(MsgID)}},
              {{string, "a"}, {dict, Params}}]},
    etorrent_bcoding:encode(Msg).

encode_response(MsgID, Values) ->
    Msg = {dict, [
              {{string, "y"}, {string, "r"}},
              {{string, "t"}, {string, binary_to_list(MsgID)}},
              {{string, "r"}, {dict, Values}}]},
    etorrent_bcoding:encode(Msg).

method_to_string(ping) -> "ping";
method_to_string(find_node) -> "find_node";
method_to_string(get_peers) -> "get_peers";
method_to_string(announce) -> "announce_peer".

string_to_method("ping") -> ping;
string_to_method("find_node") -> find_node;
string_to_method("get_peers") -> get_peers;
string_to_method("announce_peer") -> announce.



compact_to_peers(<<>>) ->
    [];
compact_to_peers(<<A0, A1, A2, A3, Port:16, Rest/binary>>) ->
    Addr = {A0, A1, A2, A3},
    [{Addr, Port}|compact_to_peers(Rest)].

peers_to_compact(PeerList) ->
    peers_to_compact(PeerList, <<>>).
peers_to_compact([], Acc) ->
    Acc;
peers_to_compact([{{A0, A1, A2, A3}, Port}|T], Acc) ->
    CPeer = <<A0, A1, A2, A3, Port:16>>,
    peers_to_compact(T, <<Acc/binary, CPeer/binary>>).

compact_to_node_infos(<<>>) ->
    [];
compact_to_node_infos(<<ID:20/binary, A0, A1, A2, A3,
                        Port:16, Rest/binary>>) ->
    IP = {A0, A1, A2, A3},
    NodeInfo = {ID, IP, Port},
    [NodeInfo|compact_to_node_infos(Rest)].

node_infos_to_compact(NodeList) ->
    node_infos_to_compact(NodeList, <<>>).
node_infos_to_compact([], Acc) ->
    Acc;
node_infos_to_compact([{ID, {A0, A1, A2, A3}, Port}|T], Acc) ->
    CNode = <<ID:20/binary, A0, A1, A2, A3, Port:16>>,
    node_infos_to_compact(T, <<Acc/binary, CNode/binary>>).

%
%
%
%query_ping_0_test() ->
%    Enc = "d1:ad2:id20:abcdefghij0123456789e1:q4:ping1:t2:aa1:y1:qe",
%    Res = bencode_to_query(Enc),
%    {dht_query, ping, ID, Params} = Res,
%    ?assertEqual(<<"aa">>, ID),
%    ?assertEqual(<<"abcdefghij0123456789">>, fetch_id(Params)).
%
%query_find_node_0_test() ->
%    Enc = "d1:ad2:id20:abcdefghij01234567896:"
%        ++"target20:mnopqrstuvwxyz123456e1:q9:find_node1:t2:aa1:y1:qe",
%    Res = bencode_to_query(Enc),
%    {dht_query, find_node, ID, Params} = Res,
%    ?assertEqual(<<"aa">>, ID),
%    ?assertEqual(<<"abcdefghij0123456789">>, fetch_id(Params)),
%    ?assertEqual(<<"mnopqrstuvwxyz123456">>, fetch_target(Params)).
%
%query_get_peers_0_test() ->
%    Enc = "d1:ad2:id20:abcdefghij01234567899:info_hash"
%        ++"20:mnopqrstuvwxyz123456e1:q9:get_peers1:t2:aa1:y1:qe",
%    Res = bencode_to_query(Enc),
%    {dht_query, get_peers, ID, Params} = Res,
%    ?assertEqual(<<"aa">>, ID),
%    ?assertEqual(<<"abcdefghij0123456789">>, fetch_id(Params)),
%    ?assertEqual(<<"mnopqrstuvwxyz123456">>, fetch_info_hash(Params)).
%
%query_announce_peer_0_test() ->
%    Enc = "d1:ad2:id20:abcdefghij01234567899:info_hash20:"
%        ++"mnopqrstuvwxyz1234564:porti6881e5:token8:aoeusnthe1:"
%        ++"q13:announce_peer1:t2:aa1:y1:qe",
%    Res = bencode_to_query(Enc),
%    {dht_query, announce, ID, Params} = Res,
%    ?assertEqual(<<"aa">>, ID),
%    ?assertEqual(<<"abcdefghij0123456789">>, fetch_id(Params)),
%    ?assertEqual(<<"mnopqrstuvwxyz123456">>, fetch_info_hash(Params)),
%    ?assertEqual(6881, fetch_port(Params)),
%    ?assertEqual(<<"aoeusnth">>, fetch_token(Params)).
%
%resp_ping_0_test() ->
%    Enc = "d1:rd2:id20:mnopqrstuvwxyz123456e1:t2:aa1:y1:re",
%    Res = bencode_to_response(Enc),
%    {dht_response, ID, Values} = Res,
%    ?assertEqual(<<"aa">>, ID),
%    ?assertEqual(<<"mnopqrstuvwxyz123456">>, fetch_id(Values)).
%
%resp_find_peer_0_test() ->
%    Enc = "d1:rd2:id20:0123456789abcdefghij5:nodes0:e1:t2:aa1:y1:re",
%    Res = bencode_to_response(Enc),
%    {dht_response, ID, Values} = Res,
%    ?assertEqual(<<"aa">>, ID),
%    ?assertEqual(<<"0123456789abcdefghij">>, fetch_id(Values)),
%    ?assertEqual([], fetch_nodes(Values)).
%
%resp_find_peer_1_test() ->
%    Enc = "d1:rd2:id20:0123456789abcdefghij5:nodes6:"
%        ++ [0,0,0,0,0,0] ++ "e1:t2:aa1:y1:re",
%    Res = bencode_to_response(Enc),
%    {dht_response, ID, Values} = Res,
%    ?assertEqual(<<"aa">>, ID),
%    ?assertEqual(<<"0123456789abcdefghij">>, fetch_id(Values)),
%    ?assertEqual([{{0,0,0,0}, 0}], fetch_nodes(Values)).
%
%resp_get_peers_0_test() ->
%    Enc = "d1:rd2:id20:abcdefghij01234567895:token8:aoeusnth6:valuesl6:axje.u6:idhtnmee1:t2:aa1:y1:re",
%    Res = bencode_to_response(Enc),
%    {dht_response, ID, Values} = Res,
%    ?assertEqual(<<"aa">>, ID),
%    ?assertEqual(<<"abcdefghij0123456789">>, fetch_id(Values)),
%    ?assertEqual(<<"aoeusnth">>, fetch_token(Values)),
%    ?assertEqual({true, [{{97,120,106,101},11893}, {{105,100,104,116}, 28269}]}, fetch_peers(Values)).
%
%resp_get_peers_1_test() ->
%    Enc = "d1:rd2:id20:abcdefghij01234567895:nodes6:def4565:token8:aoeusnthe1:t2:aa1:y1:re",
%    Res = bencode_to_response(Enc),
%    {dht_response, ID, Values} = Res,
%    ?assertEqual(<<"aa">>, ID),
%    ?assertEqual(<<"abcdefghij0123456789">>, fetch_id(Values)),
%    ?assertEqual(<<"aoeusnth">>, fetch_token(Values)),
%    ?assertEqual({false, [{{100,101,102,52},13622}]}, fetch_peers(Values)).
%
%resp_announce_peer_0_test() ->
%    Enc = "d1:rd2:id20:mnopqrstuvwxyz123456e1:t2:aa1:y1:re",
%    Res = bencode_to_response(Enc),
%    {dht_response, ID, Values} = Res,
%    ?assertEqual(<<"aa">>, ID),
%    ?assertEqual(<<"mnopqrstuvwxyz123456">>, fetch_id(Values)).
%
%%
%% Also run a test which asserts that the properties
%% defined in this module holds.
%
%properties_test() ->
%    ?assert(?MODULE:check()).
%
%
% Simple properties checking decode/encode functions
%
%octet() ->
%    choose(0, 255).
%
%portnum() ->
%    choose(0, 16#FFFF).
%
%dht_node() ->
%    {{octet(), octet(), octet(), octet()}, portnum()}.
%
%node_id() ->
%    binary(20).
%
%info_hash() ->
%    binary(20).
%
%token() ->
%    binary(20).
%
%transaction() ->
%    binary(2).
%
%ping_query() ->
%    {ping, [{<<"id">>, node_id()}]}.
%
%find_node_query() ->
%    {find_node, [{<<"id">>, node_id()},
%                 {<<"target">>, node_id()}]}.
%
%get_peers_query() ->
%    {get_peers, [{<<"id">>, node_id()},
%                 {<<"info_hash">>, node_id()}]}.
%
%announce_query() ->
%    {announce, [{<<"id">>, node_id()},
%                {<<"info_hash">>, node_id()},
%                {<<"token">>, token()},
%                {<<"port">>, portnum()}]}.
%
%dht_query() ->
%    All = [ping_query(), find_node_query(), get_peers_query(), announce_query()],
%    oneof([{dht_query, Method, transaction(), lists:sort(Params)}
%          || {Method, Params} <- All]).
%
%
%prop_inv_compact() ->
%    ?FORALL(Input, list(dht_node()),
%        begin
%            Compact = peers_to_compact(Input),
%            Output = compact_to_peers(iolist_to_binary(Compact)),
%            Input =:= Output
%        end).
%
%
%prop_query_inv() ->
%    ?FORALL(InQ, dht_query(),
%        begin
%            OutQ = bencode_to_query(query_to_bencode(InQ)),
%            OutQ =:= InQ
%        end).
