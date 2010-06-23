-module(etorrent_webui).

-include("etorrent_version.hrl").
-include("etorrent_torrent.hrl").
-include("etorrent_mnesia_table.hrl").

-export([list/3, log/3]).

%% =======================================================================
% @doc Request retrieval of the in-memory log file
% @end
-spec log(binary(), ignore, ignore) -> ok.
log(SessId, _Env, _Input) ->
    Entries = etorrent_memory_logger:all_entries(),
    [ok = mod_esi:deliver(SessId, format_log_entry(E)) ||
        E <- lists:keysort(1, Entries)],
    ok.

% @doc Request retrieval of the list of currently serving torrents
% @end
-spec list(binary(), ignore, ignore) -> ok.
list(SessID, _Env, _Input) ->
    {ok, Rates2} = list_rates(),
    ok = mod_esi:deliver(SessID, table_header()),
    {ok, Table} = list_torrents(),
    ok = mod_esi:deliver(SessID, Table),
    ok = mod_esi:deliver(SessID, table_footer()),
    ok = mod_esi:deliver(SessID, Rates2),
    ok.

%% =======================================================================
format_log_entry({_Now, LTime, Event}) ->
    io_lib:format("<span id='time'>~s</span><span id='event'>~p</span><br>~n",
        [etorrent_utils:date_str(LTime), Event]).

list_rates() ->
    {DownloadRate, UploadRate} = etorrent_rate_mgr:global_rate(),
    R2 = io_lib:format("<p>Rate Up/Down: ~8.2f / ~8.2f</p>",
                        [UploadRate / 1024.0, DownloadRate / 1024.0]),
    {ok, R2}.

table_header() ->
    "<table id=\"torrent_table\"><thead>" ++
    "<tr><th>FName</th><th>Id</th><th>Total (MiB)</th><th>Left (MiB)</th><th>Uploaded (MiB)</th><th>Downloaded (MiB)</th>" ++
    "<th>L/S</th><th>Complete</th><th>Rate</th></tr></thead><tbody>".

list_torrents() ->
    A = etorrent_torrent:all(),
    Rows = lists:map(
        fun (R) ->
                {atomic, [#tracking_map { filename = FN, _=_}]} =
                    etorrent_tracking_map:select(R#torrent.id),
                io_lib:format("<tr><td>~s</td><td>~3.B</td><td>~11.1f</td><td>~11.1f</td><td>~11.1f</td><td>~11.1f</td>"++
                              "<td>~3.B / ~3.B</td><td>~7.1f%</td>" ++
                              "<td><span id=\"~s\">~s</span>~9.B / ~9.B / ~9.B</td></tr>~n",
                        [strip_torrent(FN),
                         R#torrent.id,
                         R#torrent.total / (1024 * 1024),
                         R#torrent.left  / (1024 * 1024),
                         R#torrent.uploaded / (1024 * 1024),
                         R#torrent.downloaded / (1024 * 1024),
                         R#torrent.leechers,
                         R#torrent.seeders,
                         percent_complete(R),
                         case R#torrent.state of
                            leeching -> "sparkline-leech";
                            seeding  -> "sparkline-seed"
                         end,
                         show_sparkline(
                             lists:reverse(R#torrent.rate_sparkline)),
                         round(lists:max(R#torrent.rate_sparkline) / 1024),
                         case R#torrent.rate_sparkline of
                            []      -> 0;
                            [F | _] -> round(F / 1024)
                         end,
                         round(lists:min(R#torrent.rate_sparkline) / 1024)])
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
