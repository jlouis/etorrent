-module(etorrent_mnesia_init).

-include_lib("stdlib/include/qlc.hrl").
-include("etorrent_mnesia_table.hrl").

-export([init/0, wait/0]).

init() ->
    mnesia:create_table(sequence,
			[{attributes, record_info(fields, sequence)}]),

    mnesia:create_table(tracking_map,
			[{attributes, record_info(fields, tracking_map)}]),

    mnesia:create_table(path_map,
			[{attributes, record_info(fields, path_map)},
			 {index, [path]}]),

    mnesia:create_table(torrent,
			[{attributes, record_info(fields, torrent)}]),
    mnesia:create_table(torrent_c_pieces,
			[{attributes, record_info(fields, torrent_c_pieces)}]),

    mnesia:create_table(peer,
			[{attributes, record_info(fields, peer)},
			 {index, [torrent_id]}]),

    mnesia:create_table(piece,
			[{attributes, record_info(fields, piece)},
			 {index, [state, id]}]),

    mnesia:create_table(piece_diskstate,
			[{attributes, record_info(fields, piece_diskstate)},
			 {disc_copies, [node()]}]),

    mnesia:create_table(chunk,
			[{attributes, record_info(fields, chunk)}]),
    wait().

wait() ->
    BaseTables = [sequence, tracking_map, path_map, torrent,
		  torrent_c_pieces, peer, piece, piece_diskstate, chunk],
    mnesia:wait_for_tables(BaseTables, 5000).





