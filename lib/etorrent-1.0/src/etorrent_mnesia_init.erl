-include_lib("stdlib/include/qlc.hrl").
-include("etorrent_mnesia_table.hrl").

init() ->
    mnesia:create_table(tracking_map,
			[{attributes, record_info(fields, tracking_map)}]).

