-module(etorrent_dht).
-behaviour(supervisor).
-include("types.hrl").
-export([start_link/1,
         start_link/2,
         integer_id/1,
         list_id/1,
         random_id/0,
         closest_to/3,
         distance/2,
         find_self/0]).

-spec integer_id(list(byte())) -> nodeid().
-spec list_id(nodeid()) -> list(byte()).
-spec random_id() -> nodeid().
-spec closest_to(nodeid(), list(nodeinfo()), integer()) ->
    list(nodeinfo()).
-spec distance(nodeid(), nodeid()) -> nodeid().

% supervisor callbacks
-export([init/1]).

start_link(DHTPort) ->
    start_link(DHTPort, "etorrent_dht.persistent").



start_link(DHTPort, StateFile) ->
    _ = etorrent_dht_tracker:start_link(),
    SupName = {local, etorrent_dht_sup},
    SupArgs = [{port, DHTPort}, {file, StateFile}],
    supervisor:start_link(SupName, ?MODULE, SupArgs).


init(Args) ->
    Port = proplists:get_value(port, Args),
    File = proplists:get_value(file, Args),
    {ok, {{one_for_one, 1, 60}, [
        {dht_state_srv,
            {etorrent_dht_state, start_link, [File]},
            permanent, 2000, worker, dynamic},
        {dht_socket_srv,
            {etorrent_dht_net, start_link, [Port]},
            permanent, 1000, worker, dynamic}]}}.

find_self() ->
    Self = etorrent_dht_state:node_id(),
    etorrent_dht_net:find_node_search(Self).

integer_id(<<ID:160>>) ->
    ID;
integer_id(StrID) when is_list(StrID) ->
    integer_id(list_to_binary(StrID)).

list_id(ID) when is_integer(ID) ->
    binary_to_list(<<ID:160>>).

random_id() ->
    Byte  = fun() -> random:uniform(256) - 1 end,
    Bytes = [Byte() || _ <- lists:seq(1, 20)],
    integer_id(Bytes).

closest_to(InfoHash, NodeList, NumNodes) ->
    WithDist = [{distance(ID, InfoHash), ID, IP, Port}
               || {ID, IP, Port} <- NodeList],
    Sorted = lists:sort(WithDist),
    Limited = if
    (length(Sorted) =< NumNodes) -> Sorted;
    (length(Sorted) >  NumNodes)  ->
        {Head, _Tail} = lists:split(NumNodes, Sorted),
        Head
    end,
    [{NID, NIP, NPort} || {_, NID, NIP, NPort} <- Limited].

distance(BID0, BID1) when is_binary(BID0), is_binary(BID1) ->
    <<ID0:160>> = BID0,
    <<ID1:160>> = BID1,
    ID0 bxor ID1;
distance(ID0, ID1) when is_integer(ID0), is_integer(ID1) ->
    ID0 bxor ID1.
