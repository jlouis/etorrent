-module(etorrent_dht_net).
-include("types.hrl").
-behaviour(gen_server).
-import(etorrent_bcoding, [search_dict/2, search_dict_default/3]).
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
         get_peers/3,
         get_peers_search/1,
         announce/5,
         return/4]).

-spec node_port() -> portnum().
-spec ping(ipaddr(), portnum()) -> pang | nodeid().
-spec find_node(ipaddr(), portnum(), nodeid()) ->
    {'error', 'timeout'} | {nodeid(), list(nodeinfo())}.
-spec find_node_search(nodeid()) -> list(nodeinfo()).
-spec get_peers(ipaddr(), portnum(), infohash()) ->
    {nodeid(), token(), list(peerinfo()), list(nodeinfo())}.
-spec get_peers_search(infohash()) ->
    {list(trackerinfo()), list(peerinfo()), list(nodeinfo())}.
-spec announce(ipaddr(), portnum(), infohash(), token(), portnum()) ->
    {'error', 'timeout'} | nodeid().
-spec return(ipaddr(), portnum(), transaction(), list()) -> 'ok'.

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
    socket,
    sent,
    tokens
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

node_port() ->
    gen_server:call(srv_name(), {get_node_port}).

%
%
%
ping(IP, Port) ->
    case gen_server:call(srv_name(), {ping, IP, Port}) of
        timeout -> pang;
        Reply   ->
            {string,LID} = search_dict({string, "id"}, Reply),
            etorrent_dht:integer_id(LID)
    end.

%
%
%
find_node(IP, Port, Target)  ->
    case gen_server:call(srv_name(), {find_node, IP, Port, Target}) of
        timeout ->
            {error, timeout};
        Values  ->
            {string,LID} = search_dict({string, "id"}, Values),
            ID = etorrent_dht:integer_id(LID),
            {string,LCompact} = search_dict({string, "nodes"}, Values),
            Nodes = compact_to_node_infos(list_to_binary(LCompact)),
            etorrent_dht_state:log_request_success(ID, IP, Port),
            {ID, Nodes}
    end.




%
% Recursively search for the 100 nodes that are the closest to
% the local DHT node.
%
% Keep tabs on:
%     - Which nodes has been queried?
%     - Which nodes has responded?
%     - Which nodes has not been queried?
find_node_search(NodeID) ->
    Width = search_width(),
    Retry = search_retries(),
    dht_iter_search(find_node, NodeID, Width, Retry).

get_peers_search(InfoHash) ->
    Width = search_width(),
    Retry = search_retries(),
    dht_iter_search(get_peers, InfoHash, Width, Retry).

dht_iter_search(SearchType, Target, Width, Retry)  ->
    Next     = etorrent_dht_state:closest_to(Target, Width),
    WithDist = [{distance(ID, Target), ID, IP, Port} || {ID, IP, Port} <- Next],
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
    end || {{Dist, ID, IP, Port}, RetVal} <- WithArgs],
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


get_peers(IP, Port, InfoHash)  ->
    case (catch do_get_peers(IP, Port, InfoHash)) of
        {'EXIT', _} -> {error, response};
        Other -> Other
    end.

do_get_peers(IP, Port, InfoHash) ->
    case gen_server:call(srv_name(), {get_peers, IP, Port, InfoHash}) of
        timeout -> {error, timeout};
        Values  ->
            {string,LID} = search_dict({string, "id"}, Values),
            ID = etorrent_dht:integer_id(LID),
            {string,LToken} = search_dict({string,"token"}, Values),
            Token = list_to_binary(LToken),
            NoPeers = make_ref(),
            MaybePeers = search_dict_default({string,"values"}, Values, NoPeers),
            {Peers, Nodes} = case MaybePeers of
                NoPeers ->
                    {string,LCompact} = search_dict({string,"nodes"}, Values),
                    INodes = compact_to_node_infos(list_to_binary(LCompact)),
                    {[], INodes};
                {list, PeerStrings} ->
                    BinPeers = [list_to_binary(S) || {string,S} <- PeerStrings],
                    PeerLists = [compact_to_peers(N) || N <- BinPeers],
                    IPeers = lists:flatten(PeerLists),
                    {IPeers, []}
            end,
            {ID, Token, Peers, Nodes}
    end.

%
%
%
announce(IP, Port, InfoHash, Token, BTPort) ->
    Announce = {announce, IP, Port, InfoHash, Token, BTPort},
    case gen_server:call(srv_name(), Announce) of
        timeout -> {error, timeout};
        Reply   ->
            {string, LID} = search_dict({string, "id"}, Reply),
            etorrent_dht:integer_id(LID)
    end.

%
%
%
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
    Self = etorrent_dht_state:node_id(),
    LSelf = etorrent_dht:list_id(Self),
    Args = [{{string, "id"}, {string, LSelf}}],
    do_send_query('ping', Args, IP, Port, From, State);

handle_call({find_node, IP, Port, Target}, From, State) ->
    Self = etorrent_dht_state:node_id(),
    LSelf = etorrent_dht:list_id(Self),
    LTarget = etorrent_dht:list_id(Target),
    Args = [{{string, "id"}, {string, LSelf}},
            {{string, "target"}, {string, LTarget}}],
    do_send_query('find_node', Args, IP, Port, From, State);

handle_call({get_peers, IP, Port, InfoHash}, From, State) ->
    Self = etorrent_dht_state:node_id(),
    LSelf = etorrent_dht:list_id(Self),
    LHash = etorrent_dht:list_id(InfoHash),
    Args = [{{string, "id"}, {string, LSelf}},
            {{string, "info_hash"}, {string, LHash}}],
    do_send_query('get_peers', Args, IP, Port, From, State);

handle_call({announce, IP, Port, InfoHash, Token, BTPort}, From, State) ->
    Self = etorrent_dht_state:node_id(),
    LSelf = etorrent_dht:list_id(Self),
    LHash = etorrent_dht:list_id(InfoHash),
    LToken = binary_to_list(Token),
    Args = [{{string, "id"}, {string, LSelf}},
            {{string, "info_hash"}, {string, LHash}},
            {{string, "port"}, {integer, BTPort}},
            {{string, "token"}, {string, LToken}}],
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
                    {string, SNID} = search_dict({string, "id"}, Params),
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

terminate(_, State) ->
    (catch gen_udp:close(State#state.socket)),
    #state{sent=Sent} = State,
    LSent = gb_trees:values(Sent),
    _ = [catch gen_server:reply(Client, timeout) || {Client, _} <- LSent],
    _ = [catch cancel_timeout(TRef) || {_, TRef} <- LSent],
    {ok, State}.

code_change(_, _, State) ->
    {ok, State}.

common_values(Self) ->
    [{{string, "id"}, {string, etorrent_dht:list_id(Self)}}].

-spec handle_query(dht_qtype(), bdict(), ipaddr(),
                  portnum(), transaction(), nodeid(), _) -> 'ok'.

handle_query('ping', _, IP, Port, MsgID, Self, _Tokens) ->
    return(IP, Port, MsgID, common_values(Self));

handle_query('find_node', Params, IP, Port, MsgID, Self, _Tokens) ->
    {string, LTarget} = search_dict({string, "target"}, Params),
    Target = etorrent_dht:integer_id(LTarget),
    CloseNodes = etorrent_dht_state:closest_to(Target),
    BinCompact = node_infos_to_compact(CloseNodes),
    LCompact = binary_to_list(BinCompact),
    Values = [{{string, "nodes"}, {string, LCompact}}],
    return(IP, Port, MsgID, common_values(Self) ++ Values);

handle_query('get_peers', Params, IP, Port, MsgID, Self, Tokens) ->
    {string, LHash} = search_dict({string, "info_hash"}, Params),
    InfoHash = etorrent_dht:integer_id(LHash),
    Values = case etorrent_dht_tracker:get_peers(InfoHash) of
        [] ->
            Nodes = etorrent_dht_state:closest_to(InfoHash),
            BinCompact = node_infos_to_compact(Nodes),
            LCompact = binary_to_list(BinCompact),
            [{{string, "nodes"}, {string, LCompact}}];
        Peers ->
            PeerBins = [peers_to_compact([P]) || P <- Peers],
            PeerList = {list, [{string, binary_to_list(P)} || P <- PeerBins]},
            [{{string, "values"}, PeerList}]
    end,
    LToken = binary_to_list(token_value(IP, Port, Tokens)),
    TokenVals = [{{string, "token"}, {string, LToken}}],
    return(IP, Port, MsgID, common_values(Self) ++ TokenVals ++ Values);

handle_query('announce', Params, IP, Port, MsgID, Self, Tokens) ->
    {string, LHash} = search_dict({string, "info_hash"}, Params),
    InfoHash = etorrent_dht:integer_id(LHash),
    {integer, BTPort} = search_dict({string, "port"}, Params),
    {string, LToken} = search_dict({string, "token"}, Params),
    Token = list_to_binary(LToken),
    _ = case is_valid_token(Token, IP, Port, Tokens) of
        true ->
            etorrent_dht_tracker:announce(InfoHash, IP, BTPort);
        false ->
            error_logger:error_msg("Invalid token from ~w:~w ~w", [IP, Port, Token])
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
% Calculate the token value for a client based on the % client's IP address
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
% of based on a token that is not recent enough.
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
            {list, Error} = search_dict({string, "e"}, Msg),
            [{integer, ECode}, {string, EMsg}] = Error,
            {error, MsgID, ECode, EMsg}
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
