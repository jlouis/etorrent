-module(etorrent_dht).
-export([start/1,
         start/2,
         random_id/0,
         closest_to/3,
         distance/2]).

-export([find_self/0]).

start(DHTPort) ->
    start(DHTPort, "etorrent_dht.persistent").

start(DHTPort, StateFile) ->
    _ = etorrent_dht_tracker:start_link(),
    {ok, _} = etorrent_dht_state:start_link(StateFile),
    {ok, _} = etorrent_dht_net:start_link(DHTPort),
    ok.

find_self() ->
    Self = etorrent_dht_state:node_id(),
    etorrent_dht_net:find_node_search(Self).

random_id() ->
    Byte  = fun() -> random:uniform(256) - 1 end,
    Bytes = [Byte() || _ <- lists:seq(1, 20)],
    list_to_binary(Bytes).

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

distance(BID0, BID1) when is_binary(BID0), is_binary(BID1) ->
    <<ID0:160>> = BID0,
    <<ID1:160>> = BID1,
    ID0 bxor ID1;
distance(ID0, ID1) when is_integer(ID0), is_integer(ID1) ->
    ID0 bxor ID1.
