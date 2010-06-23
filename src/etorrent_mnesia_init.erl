-module(etorrent_mnesia_init).

-include_lib("stdlib/include/qlc.hrl").
-include("etorrent_mnesia_table.hrl").

-export([init/0, wait/0]).

%% =======================================================================

% @doc Initialize the main mnesia tables
% <p>This function provides the spec of the mnesia tables attributes as well.</p>
% @end
-spec init() -> ok.
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

% @doc Wait for the main mnesia tables to become initialized.
% <p>If we do not wait for the tables, we risk a race condition when processes
%    want to insert data into the tables. It takes milliseconds to initialize and
%    is only done once in the code.</p>
% @end
-spec wait() -> ok.
wait() ->
    BaseTables = [tracking_map, path_map, peer],
    mnesia:wait_for_tables(BaseTables, 5000).

