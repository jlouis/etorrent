-module(etorrent_mnesia_init).

-include_lib("stdlib/include/qlc.hrl").
-include("etorrent_mnesia_table.hrl").

-export([init/0]).

init() ->
    mnesia:create_table(tracking_map,
			[{attributes, record_info(fields, tracking_map)}]),
    mnesia:create_table(info_hash,
			[{attributes, record_info(fields, info_hash)}]).


