%% @doc Serve the jQuery front end with AJAX responses
%% <p>This module exists solely to serve the jQuery frontend with
%% responses to its AJAX requests. Basically, a jQuery script is
%% statically served and then that script callbacks to this module to
%% get the updates. That way, we keep static and dynamic data nicely split.
%% </p>
%% @end
-module(etorrent_webui).

-include("etorrent_version.hrl").
-export([list/3, log/3]).

-ignore_xref([{list, 3}, {log, 3}]).
%% =======================================================================

%% @doc Request retrieval of the in-memory log file
%% @end
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
    ["<table id=\"torrent_table\"><thead>",
     "<tr><th>Id</th>","<th>FName</th>",
     "<th>Total (MiB)</th>","<th>Left (MiB)</th>",
     "<th>Uploaded/Downloaded (MiB)</th>",
     "<th>Ratio</th>",
     "<th>L/S</th><th>Complete</th>",
     "<th>Rate</th><th>Boxplot</th></tr></thead><tbody>"].

ratio(_Up, 0)   -> 0.0;
ratio(_Up, 0.0) -> 0.0;
ratio(Up, Down) -> Up / Down.

list_torrents() ->
    A = etorrent_torrent:all(),
    Rows = [begin
		Id = proplists:get_value(id, R),
		SL = proplists:get_value(rate_sparkline, R),
                {value, PL} = etorrent_table:get_torrent(Id),
		Uploaded = proplists:get_value(uploaded, R) +
		           proplists:get_value(all_time_uploaded, R),
		Downloaded = proplists:get_value(downloaded, R) +
		             proplists:get_value(all_time_downloaded, R),
		io_lib:format(
		  "<tr><td>~3.B</td><td>~s</td><td>~11.1f</td>" ++
		  "<td>~11.1f</td><td>~11.1f / ~11.1f</td>"++
		  "<td>~.3f</td>"++
		  "<td>~3.B / ~3.B</td><td>~7.1f%</td>" ++
		  "<td><span id=\"~s\">~s</span>~9.B / ~9.B / ~9.B</td>" ++
		  "<td><span id=\"boxplot\">~s</td></tr>~n",
		  [Id,
		   strip_torrent(proplists:get_value(filename, PL)),
		   proplists:get_value(total, R) / (1024 * 1024),
		   proplists:get_value(left, R) / (1024 * 1024),
		   Uploaded / (1024 * 1024),
		   Downloaded / (1024 * 1024),
		   ratio(Uploaded, Downloaded),
		   proplists:get_value(leechers, R),
		   proplists:get_value(seeders, R),
		   percent_complete(R),
		   case proplists:get_value(state, R) of
		       seeding  -> "sparkline-seed";
		       leeching -> "sparkline-leech";
		       endgame  -> "sparkline-leech";
		       unknown ->  "sparkline-leech"
		   end,
		   show_sparkline(lists:reverse(SL)),
		   round(lists:max(SL) / 1024),
		   case SL of
		       %% []      -> 0;
		       [F | _] -> round(F / 1024)
		   end,
		   round(lists:min(SL) / 1024),
		   show_sparkline(lists:reverse(SL))])
	    end || R <- A],
    {ok, Rows}.

percent_complete(R) ->
    %% left / complete * 100 = % done
    T = proplists:get_value(total, R),
    L = proplists:get_value(left, R),
    (T - L) / T * 100.

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
