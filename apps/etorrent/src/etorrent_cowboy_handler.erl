-module(etorrent_cowboy_handler).


-export([init/3, handle/2, terminate/2]).



init({tcp, http}, Req, _Opts) ->
    {ok, Req, undefined_state}.

html_type() ->
    [MT] = mimetypes:extension(<<"html">>),
    MT.

handle(Req, State) ->
    {Path, PathReq} = cowboy_http_req:path(Req),
    case Path of
        [<<"ajax">>, <<"etorrent_webui">>, <<"log">>] ->
            Entries = etorrent_query:log_list(),
            Rep = [format_log_entry(E) ||
                      E <- lists:sort(
                             fun(X, Y) ->
                                     proplists:get_value(time, X)
                                         >= proplists:get_value(time, Y)
                             end,
                             Entries)],
            {ok, RepReq} =
                cowboy_http_req:reply(200, [{'Content-Type', html_type()}],
                                      Rep, PathReq),
            {ok, RepReq, State};
        [<<"ajax">>, <<"etorrent_webui">>, <<"log_json">>] ->
            Entries = etorrent_query:log_list(),
            Rep = dwrap(Entries),
            {ok, RepReq} =
                cowboy_http_req:reply(200, [{'Content-Type', html_type()}],
                                      Rep, PathReq),
            {ok, RepReq, State};
        [<<"ajax">>, <<"etorrent_webui">>, <<"list">>] ->
            {ok, Rates} = list_rates(),
            {ok, Table} = list_torrents(),
            Reply = [table_header(),
                     Table,
                     table_footer(),
                     Rates],
            {ok, RepReq} = cowboy_http_req:reply(
                             200, [{'Content-Type', html_type()}],
                             Reply, PathReq),
            {ok, RepReq, State};
        [] ->
            handle_static_file(PathReq, State, ["index.html"]);
        OtherPath ->
            handle_static_file(PathReq,
                               State,
                               [binary_to_list(X) || X <- OtherPath])
    end.

handle_static_file(Req, State, Path) ->
    Priv = code:priv_dir(etorrent),
    F = filename:join([Priv, "webui", "htdocs" | sanitize(Path)]),
    case file:read_file(F) of
        {ok, B} ->
            MimeType = case mimetypes:filename(F) of
                           unknown -> <<"text/plain">>;
                           [Otherwise]  -> Otherwise
                       end,
            {ok, RepReq} = cowboy_http_req:reply(
                             200,
                             [{'Content-Type', MimeType }], B, Req),
            {ok, RepReq, State};
        {error, enoent} ->
            {ok, RepReq} = cowboy_http_req:reply(
                             404,
                             [{'Content-Type', <<"text/plain">>}],
                             <<"Not found">>, Req),
            {ok, RepReq, State}
    end.

terminate(_Req, _State) ->
    ok.

% ----------------------------------------------------------------------

format_log_entry(PL) ->
    io_lib:format("<span id='time'>~s</span><span id='event'>~p</span><br>~n",
        [proplists:get_value(time, PL),
         proplists:get_value(event, PL)]).

%% @doc Wrap a JSON term into a 'd' dictionary. 
%%  This avoids a certain type of cross browser attacks by disallowing
%%  the outer element to be a list. The problem is that an array can
%%  be reprototyped in JS, which then opens you up to nasty attacks.
%% @end
dwrap(Term) ->
    mochijson2:encode([{d, Term}]).

list_rates() ->
    {DownloadRate, UploadRate} = etorrent_peer_states:get_global_rate(),
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
    A = etorrent_query:torrent_list(),
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

sanitize(Path) ->
    case lists:all(fun allowed/1, Path) of
        true ->
            dot_check(Path);
        false ->
            "index.html"
    end.

dot_check(Path) ->
    case dot_check1(Path) of
        ok ->
            Path;
        fail ->
            "index.html"
    end.

dot_check1([$., $/ | _]) -> fail;
dot_check1([$/, $/ | _]) -> fail;
dot_check1([$/, $. | _]) -> fail;
dot_check1([$., $. | _]) -> fail;
dot_check1([_A, B | Next]) -> dot_check1([B | Next]);
dot_check1(".") -> fail;
dot_check1("/") -> fail;
dot_check1(L) when is_list(L) -> ok.

allowed(C) when C >= $a, C =< $z -> true;
allowed(C) when C >= $A, C =< $Z -> true;
allowed(C) when C >= $0, C =< $9 -> true;
allowed(C) when C == $/;
                C == $.          -> true;
allowed(_C)                      -> false.



