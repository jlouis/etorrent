%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc TODO
%% @end
-module(etorrent_dht_net).

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

-behaviour(gen_server).
-import(etorrent_bcoding, [get_value/2, get_value/3]).
-import(etorrent_dht, [distance/2, closest_to/3]).

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
-export([start_link/1,
         node_port/0,
         ping/2,
         find_node/3,
         find_node_search/1,
         find_node_search/2,
         get_peers/3,
         get_peers_search/1,
         get_peers_search/2,
         announce/5,
         return/4]).

-type nodeinfo() :: etorrent_types:nodeinfo().
-type peerinfo() :: etorrent_types:peerinfo().
-type trackerinfo() :: etorrent_types:trackerinfo().
-type infohash() :: etorrent_types:infohash().
-type token() :: etorrent_types:token().
-type bdict() :: etorrent_types:bdict().
-type dht_qtype() :: etorrent_types:dht_qtype().
-type ipaddr() :: etorrent_types:ipaddr().
-type nodeid() :: etorrent_types:nodeid().
-type portnum() :: etorrent_types:portnum().
-type transaction() :: etorrent_types:transaction().

% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

% internal exports
-export([handle_query/7,
         decode_msg/1]).


-record(state, {
    socket :: gen_udp:socket(),
    sent   :: gb_tree(),
    tokens :: queue()
}).

%
% Type definitions and function specifications
%


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

token_lifetime() ->
    5*60*1000.

%
% Public interface
%
start_link(DHTPort) ->
    gen_server:start({local, srv_name()}, ?MODULE, [DHTPort], []).

-spec node_port() -> portnum().
node_port() ->
    gen_server:call(srv_name(), {get_node_port}).


%
%
%
-spec ping(ipaddr(), portnum()) -> pang | nodeid().
ping(IP, Port) ->
    case gen_server:call(srv_name(), {ping, IP, Port}) of
        timeout -> pang;
        Values ->
            _ID = decode_response(ping, Values)
    end.

%
%
%
-spec find_node(ipaddr(), portnum(), nodeid()) ->
    {'error', 'timeout'} | {nodeid(), list(nodeinfo())}.
find_node(IP, Port, Target)  ->
    case gen_server:call(srv_name(), {find_node, IP, Port, Target}) of
        timeout ->
            {error, timeout};
        Values  ->
            {ID, Nodes} = decode_response(find_node, Values),
            etorrent_dht_state:log_request_success(ID, IP, Port),
            {ID, Nodes}
    end.

%
%
%
-spec get_peers(ipaddr(), portnum(), infohash()) ->
    {nodeid(), token(), list(peerinfo()), list(nodeinfo())}.
get_peers(IP, Port, InfoHash)  ->
    Call = {get_peers, IP, Port, InfoHash},
    case gen_server:call(srv_name(), Call) of
        timeout ->
            {error, timeout};
        Values ->
            decode_response(get_peers, Values)
    end.

%
% Recursively search for the 100 nodes that are the closest to
% the local DHT node.
%
% Keep tabs on:
%     - Which nodes has been queried?
%     - Which nodes has responded?
%     - Which nodes has not been queried?
-spec find_node_search(nodeid()) -> list(nodeinfo()).
find_node_search(NodeID) ->
    Width = search_width(),
    Retry = search_retries(),
    Nodes = etorrent_dht_state:closest_to(NodeID, Width),
    dht_iter_search(find_node, NodeID, Width, Retry, Nodes).

-spec find_node_search(nodeid(), list(nodeinfo())) -> list(nodeinfo()).
find_node_search(NodeID, Nodes) ->
    Width = search_width(),
    Retry = search_retries(),
    dht_iter_search(find_node, NodeID, Width, Retry, Nodes).

-spec get_peers_search(infohash()) ->
    {list(trackerinfo()), list(peerinfo()), list(nodeinfo())}.
get_peers_search(InfoHash) ->
    Width = search_width(),
    Retry = search_retries(),
    Nodes = etorrent_dht_state:closest_to(InfoHash, Width), 
    dht_iter_search(get_peers, InfoHash, Width, Retry, Nodes).

-spec get_peers_search(infohash(), list(nodeinfo())) ->
    {list(trackerinfo()), list(peerinfo()), list(nodeinfo())}.
get_peers_search(InfoHash, Nodes) ->
    Width = search_width(),
    Retry = search_retries(),
    dht_iter_search(get_peers, InfoHash, Width, Retry, Nodes).
    

dht_iter_search(SearchType, Target, Width, Retry, Nodes)  ->
    WithDist = [{distance(ID, Target), ID, IP, Port} || {ID, IP, Port} <- Nodes],
    dht_iter_search(SearchType, Target, Width, Retry, 0, WithDist,
                    gb_sets:empty(), gb_sets:empty(), []).

dht_iter_search(SearchType, _, _, Retry, Retry, _,
                _, Alive, WithPeers) ->
    TmpAlive  = gb_sets:to_list(Alive),
    AliveList = [{ID, IP, Port} || {_, ID, IP, Port} <- TmpAlive],
    case SearchType of
        find_node ->
            AliveList;
        get_peers ->
            Trackers = [{ID, IP, Port, Token}
                      ||{ID, IP, Port, Token, _} <- WithPeers],
            Peers = [Peers || {_, _, _, _, Peers} <- WithPeers],
            {Trackers, Peers, AliveList}
    end;

dht_iter_search(SearchType, Target, Width, Retry, Retries,
                Next, Queried, Alive, WithPeers) ->

    % Mark all nodes in the queue as queried
    AddQueried = [{ID, IP, Port} || {_, ID, IP, Port} <- Next],
    NewQueried = gb_sets:union(Queried, gb_sets:from_list(AddQueried)),

    % Query all nodes in the queue and generate a list of
    % {Dist, ID, IP, Port, Nodes} elements
    SearchCalls = [case SearchType of
        find_node -> {?MODULE, find_node, [IP, Port, Target]};
        get_peers -> {?MODULE, get_peers, [IP, Port, Target]}
    end || {_, _, IP, Port} <- Next],
    ReturnValues = rpc:parallel_eval(SearchCalls),
    WithArgs = lists:zip(Next, ReturnValues),

    FailedCall = make_ref(),
    TmpSuccessful = [case {repack, SearchType, RetVal} of
        {repack, _, {error, timeout}} ->
            FailedCall;
        {repack, _, {error, response}} ->
            FailedCall;
        {repack, find_node, {NID, Nodes}} ->
            {{Dist, NID, IP, Port}, Nodes};
        {repack, get_peers, {NID, Token, Peers, Nodes}} ->
            {{Dist, NID, IP, Port}, {Token, Peers, Nodes}}
    end || {{Dist, _ID, IP, Port}, RetVal} <- WithArgs],
    Successful = [E || E <- TmpSuccessful, E =/= FailedCall],

    % Mark all nodes that responded as alive
    AddAlive = [N ||{{_, _, _, _}=N, _} <- Successful],
    NewAlive = gb_sets:union(Alive, gb_sets:from_list(AddAlive)),

    % Accumulate all nodes from the successful responses.
    % Calculate the relative distance to all of these nodes
    % and keep the closest nodes which has not already been
    % queried in a previous iteration
    NodeLists = [case {acc_nodes, {SearchType, Res}} of
        {acc_nodes, {find_node, Nodes}} ->
            Nodes;
        {acc_nodes, {get_peers, {_, _, Nodes}}} ->
            Nodes
    end || {_, Res} <- Successful],
    AllNodes  = lists:flatten(NodeLists),
    NewNodes  = [Node || Node <- AllNodes, not gb_sets:is_member(Node, NewQueried)],
    NewNext   = [{distance(ID, Target), ID, IP, Port}
                ||{ID, IP, Port} <- closest_to(Target, NewNodes, Width)],

    % Check if the closest node in the work queue is closer
    % to the target than the closest responsive node that was
    % found in this iteration.
    MinAliveDist = case gb_sets:size(NewAlive) of
        0 ->
            infinity;
        _ ->
            {IMinAliveDist, _, _, _} = gb_sets:smallest(NewAlive),
            IMinAliveDist
    end,

    MinQueueDist = case NewNext of
        [] ->
            infinity;
        Other ->
            {MinDist, _, _, _} = lists:min(Other),
            MinDist
    end,

    % Check if the closest node in the work queue is closer
    % to the infohash than the closest responsive node.
    NewRetries = if
        (MinQueueDist <  MinAliveDist) -> 0;
        (MinQueueDist >= MinAliveDist) -> Retries + 1
    end,

    % Accumulate the trackers and peers found if this is a get_peers search.
    NewWithPeers = case SearchType of
        find_node -> []=WithPeers;
        get_peers ->
            Tmp=[{ID, IP, Port, Token, Peers}
                || {{_, ID, IP, Port}, {Token, Peers, _}} <- Successful, Peers > []],
            WithPeers ++ Tmp
    end,

    dht_iter_search(SearchType, Target, Width, Retry, NewRetries,
                    NewNext, NewQueried, NewAlive, NewWithPeers).


%
%
%
-spec announce(ipaddr(), portnum(), infohash(), token(), portnum()) ->
    {'error', 'timeout'} | nodeid().
announce(IP, Port, InfoHash, Token, BTPort) ->
    Announce = {announce, IP, Port, InfoHash, Token, BTPort},
    case gen_server:call(srv_name(), Announce) of
        timeout -> {error, timeout};
        Values ->
            decode_response(announce, Values)
    end.

%
%
%
-spec return(ipaddr(), portnum(), transaction(), list()) -> 'ok'.
return(IP, Port, ID, Response) ->
    ok = gen_server:call(srv_name(), {return, IP, Port, ID, Response}).

init([DHTPort]) ->
    {ok, Socket} = gen_udp:open(DHTPort, socket_options()),
    State = #state{socket=Socket,
                   sent=gb_trees:empty(),
                   tokens=init_tokens(3)},
    erlang:send_after(token_lifetime(), self(), renew_token),
    {ok, State}.



timeout_reference(IP, Port, ID) ->
    Msg = {timeout, self(), IP, Port, ID},
    erlang:send_after(query_timeout(), self(), Msg).

cancel_timeout(TimeoutRef) ->
    erlang:cancel_timer(TimeoutRef).

handle_call({ping, IP, Port}, From, State) ->
    Args = common_values(),
    do_send_query('ping', Args, IP, Port, From, State);

handle_call({find_node, IP, Port, Target}, From, State) ->
    LTarget = etorrent_dht:list_id(Target),
    Args = [{<<"target">>, list_to_binary(LTarget)} | common_values()],
    do_send_query('find_node', Args, IP, Port, From, State);

handle_call({get_peers, IP, Port, InfoHash}, From, State) ->
    LHash = list_to_binary(etorrent_dht:list_id(InfoHash)),
    Args  = [{<<"info_hash">>, LHash}| common_values()],
    do_send_query('get_peers', Args, IP, Port, From, State);

handle_call({announce, IP, Port, InfoHash, Token, BTPort}, From, State) ->
    LHash = list_to_binary(etorrent_dht:list_id(InfoHash)),
    Args = [
        {<<"info_hash">>, LHash},
        {<<"port">>, BTPort},
        {<<"token">>, Token} | common_values()],
    do_send_query('announce', Args, IP, Port, From, State);

handle_call({return, IP, Port, ID, Values}, _From, State) ->
    Socket = State#state.socket,
    Response = encode_response(ID, Values),
    ok = case gen_udp:send(Socket, IP, Port, Response) of
        ok ->
            ok;
        {error, einval} ->
            error_logger:error_msg("Error (einval) when returning to ~w:~w", [IP, Port]),
            ok;
        {error, eagain} ->
            error_logger:error_msg("Error (eagain) when returning to ~w:~w", [IP, Port]),
            ok
    end,
    {reply, ok, State};

handle_call({get_node_port}, _From, State) ->
    #state{
        socket=Socket} = State,
    {ok, {_, Port}} = inet:sockname(Socket),
    {reply, Port, State};

handle_call({get_num_open}, _From, State) ->
    Sent = State#state.sent,
    NumSent = gb_trees:size(Sent),
    {reply, NumSent, State}.

do_send_query(Method, Args, IP, Port, From, State) ->
    #state{sent=Sent,
           socket=Socket} = State,

    MsgID = unique_message_id(IP, Port, Sent),
    Query = encode_query(Method, MsgID, Args),

    case gen_udp:send(Socket, IP, Port, Query) of
        ok ->
            TRef = timeout_reference(IP, Port, MsgID),
            error_logger:info_msg("Sent ~w to ~w:~w", [Method, IP, Port]),

            NewSent = store_sent_query(IP, Port, MsgID, From, TRef, Sent),
            NewState = State#state{sent=NewSent},
            {noreply, NewState};
        {error, einval} ->
            error_logger:error_msg("Error (einval) when sending ~w to ~w:~w", [Method, IP, Port]),
            {reply, timeout, State};
        {error, eagain} ->
            error_logger:error_msg("Error (eagain) when sending ~w to ~w:~w", [Method, IP, Port]),
            {reply, timeout, State}
    end.

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

handle_info(renew_token, State) ->
    #state{tokens=PrevTokens} = State,
    NewTokens = renew_token(PrevTokens),
    NewState = State#state{tokens=NewTokens},
    erlang:send_after(token_lifetime(), self(), renew_token),
    {noreply, NewState};

handle_info({udp, _Socket, IP, Port, Packet}, State) ->
    #state{
        sent=Sent,
        tokens=Tokens} = State,
    Self = etorrent_dht_state:node_id(),
    NewState = case (catch decode_msg(Packet)) of
        {'EXIT', _} ->
            error_logger:error_msg("Invalid packet from ~w:~w: ~w", [IP, Port, Packet]),
            State;

        {error, ID, Code, ErrorMsg} ->
            error_logger:error_msg("Received error from ~w:~w (~w) ~w", [IP, Port, Code, ErrorMsg]),
            case find_sent_query(IP, Port, ID, Sent) of
                error ->
                    State;
                {ok, {Client, Timeout}} ->
                    _ = cancel_timeout(Timeout),
                    _ = gen_server:reply(Client, timeout),
                    NewSent = clear_sent_query(IP, Port, ID, Sent),
                    State#state{sent=NewSent}
            end;

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
            error_logger:info_msg("Received ~w from ~w:~w", [Method, IP, Port]),
            case find_sent_query(IP, Port, ID, Sent) of
                {ok, {Client, Timeout}} ->
                    _ = cancel_timeout(Timeout),
                    _ = gen_server:reply(Client, timeout),
                    error_logger:error_msg("Bad node, don't send queries to yourself!"),
                    NewSent = clear_sent_query(IP, Port, ID, Sent),
                    State#state{sent=NewSent};
                error ->
                    SNID = get_string("id", Params),
                    NID = etorrent_dht:integer_id(SNID),
                    spawn_link(etorrent_dht_state, safe_insert_node, [NID, IP, Port]),
                    HandlerArgs = [Method, Params, IP, Port, ID, Self, Tokens],
                    spawn_link(?MODULE, handle_query, HandlerArgs),
                    State
            end
    end,
    {noreply, NewState};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_, _State) ->
    ok.

code_change(_, _, State) ->
    {ok, State}.

%% Default args. Returns a proplist of default args
common_values() ->
    Self = etorrent_dht_state:node_id(),
    common_values(Self).

common_values(Self) ->
    LSelf = etorrent_dht:list_id(Self),
    [{<<"id">>, list_to_binary(LSelf)}].

-spec handle_query(dht_qtype(), bdict(), ipaddr(),
                  portnum(), transaction(), nodeid(), _) -> 'ok'.

handle_query('ping', _, IP, Port, MsgID, Self, _Tokens) ->
    return(IP, Port, MsgID, common_values(Self));

handle_query('find_node', Params, IP, Port, MsgID, Self, _Tokens) ->
    Target = etorrent_dht:integer_id(get_value(<<"target">>, Params)),
    CloseNodes = etorrent_dht_state:closest_to(Target),
    BinCompact = node_infos_to_compact(CloseNodes),
    Values = [{<<"nodes">>, BinCompact}],
    return(IP, Port, MsgID, common_values(Self) ++ Values);

handle_query('get_peers', Params, IP, Port, MsgID, Self, Tokens) ->
    InfoHash = etorrent_dht:integer_id(get_value(<<"info_hash">>, Params)),
    Values = case etorrent_dht_tracker:get_peers(InfoHash) of
        [] ->
            Nodes = etorrent_dht_state:closest_to(InfoHash),
            BinCompact = node_infos_to_compact(Nodes),
            [{<<"nodes">>, BinCompact}];
        Peers ->
            PeerList = [peers_to_compact([P]) || P <- Peers],
            [{<<"values">>, PeerList}]
    end,
    Token = [{<<"token">>, token_value(IP, Port, Tokens)}],
    return(IP, Port, MsgID, common_values(Self) ++ Token ++ Values);

handle_query('announce', Params, IP, Port, MsgID, Self, Tokens) ->
    InfoHash = etorrent_dht:integer_id(get_value(<<"info_hash">>, Params)),
    BTPort = get_value(<<"port">>,   Params),
    Token = get_string(<<"token">>, Params),
    case is_valid_token(Token, IP, Port, Tokens) of
        true ->
            etorrent_dht_tracker:announce(InfoHash, IP, BTPort);
        false ->
            FmtArgs = [IP, Port, Token],
            error_logger:error_msg("Invalid token from ~w:~w ~w", FmtArgs)
    end,
    return(IP, Port, MsgID, common_values(Self)).

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

get_string(What, PL) ->
    etorrent_bcoding:get_binary_value(What, PL).

%
% Generate a random token value. A token value is used to filter out bogus announce
% requests, or at least announce requests from nodes that never sends get_peers requests.
%
random_token() ->
    ID0 = random:uniform(16#FFFF),
    ID1 = random:uniform(16#FFFF),
    <<ID0:16, ID1:16>>.

%
% Initialize the socket server's token queue, the size of this queue
% will be kept constant during the running-time of the server. The
% size of this queue specifies how old tokens the server will accept.
%
init_tokens(NumTokens) ->
    queue:from_list([random_token() || _ <- lists:seq(1, NumTokens)]).
%
% Calculate the token value for a client based on the client's IP address
% and Port number combined with a secret token value held by the socket server.
% This avoids the need to store unique token values in the socket server.
%
token_value(IP, Port, Token) when is_binary(Token) ->
    Hash = erlang:phash2({IP, Port, Token}),
    <<Hash:32>>;

token_value(IP, Port, Tokens) ->
    MostRecent = queue:last(Tokens),
    token_value(IP, Port, MostRecent).



%
% Check if a token value included by a node in an announce message is bogus
% (based on a token that is not recent enough).
%
is_valid_token(TokenValue, IP, Port, Tokens) ->
    ValidValues = [token_value(IP, Port, Token) || Token <- queue:to_list(Tokens)],
    lists:member(TokenValue, ValidValues).

%
% Discard the oldest token and create a new one to replace it.
%
renew_token(Tokens) ->
    {_, WithoutOldest} = queue:out(Tokens),
    queue:in(random_token(), WithoutOldest).



decode_msg(InMsg) ->
    {ok, Msg} = etorrent_bcoding:decode(InMsg),
    MsgID = get_value(<<"t">>, Msg),
    case get_value(<<"y">>, Msg) of
        <<"q">> ->
            MString = get_value(<<"q">>, Msg),
            Method  = string_to_method(MString),
            Params  = get_value(<<"a">>, Msg),
            {Method, MsgID, Params};
        <<"r">> ->
            Values = get_value(<<"r">>, Msg),
            {response, MsgID, Values};
        <<"e">> ->
            [ECode, EMsg] = get_value(<<"e">>, Msg),
            {error, MsgID, ECode, EMsg}
    end.

decode_response(ping, Values) ->
     etorrent_dht:integer_id(get_value(<<"id">>, Values));
decode_response(find_node, Values) ->
    ID = etorrent_dht:integer_id(get_value(<<"id">>, Values)),
    BinNodes = get_value(<<"nodes">>, Values),
    Nodes = compact_to_node_infos(BinNodes),
    {ID, Nodes};
decode_response(get_peers, Values) ->
    ID = etorrent_dht:integer_id(get_value(<<"id">>, Values)),
    Token = get_value(<<"token">>, Values),
    NoPeers = make_ref(),
    MaybePeers = get_value(<<"values">>, Values, NoPeers),
    {Peers, Nodes} = case MaybePeers of
        NoPeers when is_reference(NoPeers) ->
            BinCompact = get_value(<<"nodes">>, Values),
            INodes = compact_to_node_infos(BinCompact),
            {[], INodes};
        BinPeers when is_list(BinPeers) ->
            PeerLists = [compact_to_peers(N) || N <- BinPeers],
            IPeers = lists:flatten(PeerLists),
            {IPeers, []}
    end,
    {ID, Token, Peers, Nodes};
decode_response(announce, Values) ->
    etorrent_dht:integer_id(get_value(<<"id">>, Values)).



encode_query(Method, MsgID, Params) ->
    Msg = [
       {<<"y">>, <<"q">>},
       {<<"q">>, method_to_string(Method)},
       {<<"t">>, MsgID},
       {<<"a">>, Params}],
    etorrent_bcoding:encode(Msg).

encode_response(MsgID, Values) ->
    Msg = [
       {<<"y">>, <<"r">>},
       {<<"t">>, MsgID},
       {<<"r">>, Values}],
    etorrent_bcoding:encode(Msg).

method_to_string(ping) -> <<"ping">>;
method_to_string(find_node) -> <<"find_node">>;
method_to_string(get_peers) -> <<"get_peers">>;
method_to_string(announce) -> <<"announce_peer">>.

string_to_method(<<"ping">>) -> ping;
string_to_method(<<"find_node">>) -> find_node;
string_to_method(<<"get_peers">>) -> get_peers;
string_to_method(<<"announce_peer">>) -> announce.



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
compact_to_node_infos(<<ID:160, A0, A1, A2, A3,
                        Port:16, Rest/binary>>) ->
    IP = {A0, A1, A2, A3},
    NodeInfo = {ID, IP, Port},
    [NodeInfo|compact_to_node_infos(Rest)].

node_infos_to_compact(NodeList) ->
    node_infos_to_compact(NodeList, <<>>).
node_infos_to_compact([], Acc) ->
    Acc;
node_infos_to_compact([{ID, {A0, A1, A2, A3}, Port}|T], Acc) ->
    CNode = <<ID:160, A0, A1, A2, A3, Port:16>>,
    node_infos_to_compact(T, <<Acc/binary, CNode/binary>>).

-type octet() :: byte().
%-type portnum() :: char().
-type dht_node() :: {{octet(), octet(), octet(), octet()}, portnum()}.
-type integer_id() :: non_neg_integer().
-type node_id() :: integer_id().
-type info_hash() :: integer_id().
%-type token() :: binary().
%-type transaction() ::binary().

-type ping_query() ::
    {ping, transaction(), {{'id', node_id()}}}.

-type find_node_query() ::
   {find_node, transaction(),
        {{'id', node_id()}, {'target', node_id()}}}.

-type get_peers_query() ::
   {get_peers, transaction(),
        {{'id', node_id()}, {'info_hash', info_hash()}}}.

-type announce_query() ::
   {announce, transaction(),
        {{'id', node_id()}, {'info_hash', info_hash()},
         {'token', token()}, {'port', portnum()}}}.

-type dht_query() ::
    ping_query() |
    find_node_query() |
    get_peers_query() |
    announce_query().

-ifdef(EUNIT).

fetch_id(Params) ->
    get_value(<<"id">>, Params).

query_ping_0_test() ->
   Enc = "d1:ad2:id20:abcdefghij0123456789e1:q4:ping1:t2:aa1:y1:qe",
   {ping, ID, Params} = decode_msg(Enc),
   ?assertEqual(<<"aa">>, ID),
   ?assertEqual(<<"abcdefghij0123456789">>, fetch_id(Params)).

query_find_node_0_test() ->
    Enc = "d1:ad2:id20:abcdefghij01234567896:"
        ++"target20:mnopqrstuvwxyz123456e1:q9:find_node1:t2:aa1:y1:qe",
    Res = decode_msg(Enc),
    {find_node, ID, Params} = Res,
    ?assertEqual(<<"aa">>, ID),
    ?assertEqual(<<"abcdefghij0123456789">>, fetch_id(Params)),
    ?assertEqual(<<"mnopqrstuvwxyz123456">>, get_value(<<"target">>, Params)).

query_get_peers_0_test() ->
    Enc = "d1:ad2:id20:abcdefghij01234567899:info_hash"
        ++"20:mnopqrstuvwxyz123456e1:q9:get_peers1:t2:aa1:y1:qe",
    Res = decode_msg(Enc),
    {get_peers, ID, Params} = Res,
    ?assertEqual(<<"aa">>, ID),
    ?assertEqual(<<"abcdefghij0123456789">>, fetch_id(Params)),
    ?assertEqual(<<"mnopqrstuvwxyz123456">>, get_value(<<"info_hash">>,Params)).

query_announce_peer_0_test() ->
    Enc = "d1:ad2:id20:abcdefghij01234567899:info_hash20:"
        ++"mnopqrstuvwxyz1234564:porti6881e5:token8:aoeusnthe1:"
        ++"q13:announce_peer1:t2:aa1:y1:qe",
    Res = decode_msg(Enc),
    {announce, ID, Params} = Res,
    ?assertEqual(<<"aa">>, ID),
    ?assertEqual(<<"abcdefghij0123456789">>, fetch_id(Params)),
    ?assertEqual(<<"mnopqrstuvwxyz123456">>, get_value(<<"info_hash">>,Params)),
    ?assertEqual(<<"aoeusnth">>, get_value(<<"token">>, Params)),
    ?assertEqual(6881, get_value(<<"port">>, Params)).

resp_ping_0_test() ->
    Enc = "d1:rd2:id20:mnopqrstuvwxyz123456e1:t2:aa1:y1:re",
    Res = decode_msg(Enc),
    {response, MsgID, Values} = Res,
    ID = decode_response(ping, Values),
    ?assertEqual(<<"aa">>, MsgID),
    ?assertEqual(etorrent_dht:integer_id(<<"mnopqrstuvwxyz123456">>), ID).

resp_find_node_0_test() ->
    Enc = "d1:rd2:id20:0123456789abcdefghij5:nodes0:e1:t2:aa1:y1:re",
    {response, _, Values} = decode_msg(Enc),
    {ID, Nodes} = decode_response(find_node, Values),
    ?assertEqual(etorrent_dht:integer_id(<<"0123456789abcdefghij">>), ID),
    ?assertEqual([], Nodes).

resp_find_node_1_test() ->
    Enc = "d1:rd2:id20:0123456789abcdefghij5:nodes26:"
         ++ "0123456789abcdefghij" ++ [0,0,0,0,0,0] ++ "e1:t2:aa1:y1:re",
    Res = decode_msg(Enc),
    {response, _, Values} = Res,
    {_, Nodes} = decode_response(find_node, Values),
    ?assertEqual([{etorrent_dht:integer_id("0123456789abcdefghij"),
                   {0,0,0,0}, 0}], Nodes).

resp_get_peers_0_test() ->
    Enc = "d1:rd2:id20:abcdefghij01234567895:token8:aoeusnth6:values"
        ++ "l6:axje.u6:idhtnmee1:t2:aa1:y1:re",
    Res = decode_msg(Enc),
    {response, _, Values} = Res,
    {ID, Token, Peers, _Nodes} = decode_response(get_peers, Values),
    ?assertEqual(etorrent_dht:integer_id(<<"abcdefghij0123456789">>), ID),
    ?assertEqual(<<"aoeusnth">>, Token),
    ?assertEqual([{{97,120,106,101},11893}, {{105,100,104,116}, 28269}], Peers).

resp_get_peers_1_test() ->
    Enc = "d1:rd2:id20:abcdefghij01234567895:nodes26:"
        ++ "0123456789abcdefghijdef4565:token8:aoeusnthe"
        ++ "1:t2:aa1:y1:re",
    Res = decode_msg(Enc),
    {response, _, Values} = Res,
    {ID, Token, _Peers, Nodes} = decode_response(get_peers, Values),
    ?assertEqual(etorrent_dht:integer_id(<<"abcdefghij0123456789">>), ID),
    ?assertEqual(<<"aoeusnth">>, Token),
    ?assertEqual([{etorrent_dht:integer_id(<<"0123456789abcdefghij">>),
                   {100,101,102,52},13622}], Nodes).

resp_announce_peer_0_test() ->
    Enc = "d1:rd2:id20:mnopqrstuvwxyz123456e1:t2:aa1:y1:re",
    Res = decode_msg(Enc),
    {response, _, Values} = Res,
    ID = decode_response(announce, Values),
    ?assertEqual(etorrent_dht:integer_id(<<"mnopqrstuvwxyz123456">>), ID).

valid_token_test() ->
    IP = {123,132,213,231},
    Port = 1779,
    TokenValues = init_tokens(10),
    Token = token_value(IP, Port, TokenValues),
    ?assertEqual(true, is_valid_token(Token, IP, Port, TokenValues)),
    ?assertEqual(false, is_valid_token(<<"not there at all!">>,
				       IP, Port, TokenValues)).

-ifdef(PROPER).


prop_inv_compact() ->
   ?FORALL(Input, list(dht_node()),
       begin
           Compact = peers_to_compact(Input),
           Output = compact_to_peers(iolist_to_binary(Compact)),
           Input =:= Output
       end).

prop_inv_compact_test() ->
    ?assert(proper:quickcheck(prop_inv_compact())).

tobin(Atom) ->
    iolist_to_binary(atom_to_list(Atom)).

prop_query_inv() ->
   ?FORALL(TmpQ, dht_query(),
       begin
           {TmpMethod, TmpMsgId, TmpParams} = TmpQ,
           InQ  = {TmpMethod, <<0, TmpMsgId/binary>>,
                   lists:sort([{tobin(K),V} || {K, V} <- tuple_to_list(TmpParams)])},
           {Method, MsgId, Params} = InQ,
           EncQ = iolist_to_binary(encode_query(Method, MsgId, Params)),
           OutQ = decode_msg(EncQ),
           OutQ =:= InQ
       end).

prop_query_inv_test() ->
    ?assert(proper:quickcheck(prop_query_inv())).

-endif. %% EQC
-endif.
