-module(etorrent_webui).

-include("etorrent_version.hrl").
-include("etorrent_torrent.hrl").
-include("etorrent_mnesia_table.hrl").

-export([list/3]).


list(SessID, _Env, _Input) ->
    {ok, DR, Rates2} = list_rates(),
    mod_esi:deliver(SessID, table_header()),
    {ok, Table} = list_torrents(DR),
    mod_esi:deliver(SessID, Table),
    mod_esi:deliver(SessID, table_footer()),
    mod_esi:deliver(SessID, Rates2).

list_rates() ->
    {DownloadRate, UploadRate} = etorrent_rate_mgr:global_rate(),
    R2 = io_lib:format("<p>Rate Up/Down: ~8.2f / ~8.2f</p>",
                        [UploadRate / 1024.0, DownloadRate / 1024.0]),
    {ok, DownloadRate, R2}.

table_header() ->
    "<table id=\"torrent_table\"><thead>" ++
    "<tr><th>FName</th><th>Id</th><th>Total</th><th>Left</th><th>Uploaded</th><th>Downloaded</th>" ++
    "<th>L/S</th><th>Complete</th><th>ETA</th></tr></thead><tbody>".

list_torrents(DownloadRate) ->
    A = etorrent_torrent:all(),
    Rows = lists:map(
        fun (R) ->
                {DaysLeft, {HoursLeft, MinutesLeft, SecondsLeft}} =
                    etorrent_rate:eta(R#torrent.left, DownloadRate),
                {atomic, [#tracking_map { filename = FN, _=_}]} =
                    etorrent_tracking_map:select(R#torrent.id),
                io_lib:format("<tr><td>~s</td><td>~3.B</td><td>~11.B</td><td>~11.B</td><td>~11.B</td><td>~11.B</td>"++
                              "<td>~3.B / ~3.B</td><td>~7.3f%</td><td>~Bd ~Bh ~Bm ~Bs</td></tr>~n",
                        [FN,
                         R#torrent.id,
                         R#torrent.total,
                         R#torrent.left,
                         R#torrent.uploaded,
                         R#torrent.downloaded,
                         R#torrent.leechers,
                         R#torrent.seeders,
                         percent_complete(R),
             DaysLeft, HoursLeft, MinutesLeft, SecondsLeft])
        end, A),
    {ok, Rows}.

percent_complete(R) ->
    %% left / complete * 100 = % done
    (R#torrent.total - R#torrent.left) / R#torrent.total * 100.

table_footer() ->
    "</tbody></table>".

