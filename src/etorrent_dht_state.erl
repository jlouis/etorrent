-module(etorrent_dht_state).
-export([open/0,
         close/0,
         clear/0,
         save/1,
         known_nodes/0]).

% Use the process dictonary as a temporary way
% to store a list of known nodes
open() ->
    _ = put(dht_nodes, []),
    ok.

close() ->
    ok.

clear() ->
    ok.

save(Entries) ->
    Previous = get(dht_nodes),
    put(dht_nodes, ordsets:from_list(Previous ++ Entries)),
    ok.

known_nodes() ->
    get(dht_nodes).

