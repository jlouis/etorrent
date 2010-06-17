-module(etorrent_webui).

-include("etorrent_version.hrl").
-include("etorrent_torrent.hrl").
-include("etorrent_mnesia_table.hrl").

-export([list/3]).


list(SessID, _Env, _Input) ->
    {ok, Rates2} = list_rates(),
    mod_esi:deliver(SessID, table_header()),
    {ok, Table} = list_torrents(),
    mod_esi:deliver(SessID, Table),
    mod_esi:deliver(SessID, table_footer()),
    mod_esi:deliver(SessID, Rates2).

list_rates() ->
    {DownloadRate, UploadRate} = etorrent_rate_mgr:global_rate(),
    R2 = io_lib:format("<p>Rate Up/Down: ~8.2f / ~8.2f</p>",
                        [UploadRate / 1024.0, DownloadRate / 1024.0]),
    {ok, R2}.

table_header() ->
    "<table id=\"torrent_table\"><thead>" ++
    "<tr><th>FName</th><th>Id</th><th>Total</th><th>Left</th><th>Uploaded</th><th>Downloaded</th>" ++
    "<th>L/S</th><th>Complete</th><th>Rate</th></tr></thead><tbody>".

list_torrents() ->
    A = etorrent_torrent:all(),
    Rows = lists:map(
        fun (R) ->
                {atomic, [#tracking_map { filename = FN, _=_}]} =
                    etorrent_tracking_map:select(R#torrent.id),
                io_lib:format("<tr><td>~s</td><td>~3.B</td><td>~11.B</td><td>~11.B</td><td>~11.B</td><td>~11.B</td>"++
                              "<td>~3.B / ~3.B</td><td>~7.3f%</td>" ++
                              "<td><span id=\"~s\">~s</span></td></tr>~n",
                        [strip_torrent(FN),
                         R#torrent.id,
                         R#torrent.total,
                         R#torrent.left,
                         R#torrent.uploaded,
                         R#torrent.downloaded,
                         R#torrent.leechers,
                         R#torrent.seeders,
                         percent_complete(R),
                         case R#torrent.state of
                            leeching -> "sparkline-leech";
                            seeding  -> "sparkline-seed"
                         end,
                         show_sparkline(
                             lists:reverse(R#torrent.rate_sparkline))])
        end, A),
    {ok, Rows}.

percent_complete(R) ->
    %% left / complete * 100 = % done
    (R#torrent.total - R#torrent.left) / R#torrent.total * 100.

table_footer() ->
    "</tbody></table>".

strip_torrent(FileName) ->
    Tokens = string:tokens(FileName, "."),
    [_ | R] = lists:reverse(Tokens),
    string:join(lists:reverse(R), ".").

show_sparkline([]) -> "";
show_sparkline([I]) -> [conv_number(I)];
show_sparkline([I | R]) ->
    [conv_number(I), ", " | show_sparkline(R)].

conv_number(I) when is_integer(I) -> integer_to_list(I);
conv_number(F) when is_float(F)   -> float_to_list(F).

