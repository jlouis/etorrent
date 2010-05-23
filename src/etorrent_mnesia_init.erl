-module(etorrent_mnesia_init).

-include_lib("stdlib/include/qlc.hrl").
-include("etorrent_mnesia_table.hrl").

-export([init/0, wait/0]).

init() ->
    mnesia:create_table(tracking_map,
                        [{attributes, record_info(fields, tracking_map)}]),

    mnesia:create_table(path_map,
                        [{attributes, record_info(fields, path_map)},
                         {index, [path]}]),

    mnesia:create_table(peer,
                        [{attributes, record_info(fields, peer)},
                         {index, [torrent_id]}]),
    wait().

wait() ->
    BaseTables = [tracking_map, path_map, peer],
    mnesia:wait_for_tables(BaseTables, 5000).

