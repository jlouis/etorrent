-module(etorrent_mnesia_init).

-include_lib("stdlib/include/qlc.hrl").
-include("etorrent_mnesia_table.hrl").

-export([init/0]).

init() ->
    BaseTables = [tracking_map, torrent, peer, piece, chunk],
    mnesia:create_table(tracking_map,
			[{attributes, record_info(fields, tracking_map)}]),
    mnesia:create_table(torrent,
			[{attributes, record_info(fields, torrent)}]),
    mnesia:create_table(peer,
			[{attributes, record_info(fields, peer)}]),
    mnesia:create_table(piece,
			[{attributes, record_info(fields, piece)},
			 {index, [state, id]}]),
    mnesia:create_table(chunk,
			[{attributes, record_info(fields, chunk)}]),
    mnesia:wait_for_tables(BaseTables, 5000).





