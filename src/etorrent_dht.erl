-module(etorrent_dht).
-export([start/1,
         start/2,
         random_id/0,
         closest_to/3,
         distance/2]).

start(DHTPort) ->
    start(DHTPort, "etorrent_dht.persistent").

start(DHTPort, StateFile) ->
    {ok, _} = etorrent_dht_state:start_link(StateFile),
    {ok, _} = etorrent_dht_net:start_link(DHTPort),
    ok.

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

distance(BID0, BID1) ->
    <<ID0:160>> = BID0,
    <<ID1:160>> = BID1,
    ID0 bxor ID1.
