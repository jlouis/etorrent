-module(etorrent).
-behaviour(application).

-include("etorrent_version.hrl").
-include("etorrent_torrent.hrl").
-include("etorrent_mnesia_table.hrl").

-export([stop/0, start/0]).
-export([start/2, stop/1, prep_stop/1]).
-export([help/0, h/0, list/0, l/0, show/0, s/0, show/1, s/1, check/1]).

-ignore_xref([{h, 0}, {l, 0}, {'prep_stop', 1}, {s, 0}, {s,1}, {stop, 0},
              {check, 1}, {start, 0}]).

-define(RANDOM_MAX_SIZE, 999999999999).

%% @doc Start up the etorrent application.
%% <p>This is the main entry point for the etorrent application.
%% It will be ensured that needed apps are correctly up and running,
%% and then the etorrent application will be started as a permanent app
%% in the VM.</p>
%% @end
start() ->
    %% Start dependent applications
    Fun = fun(Application) ->
            case application:start(Application) of
                ok -> ok;
                {error, {already_started, Application}} -> ok
            end
          end,
    lists:foreach(Fun, [crypto, inets, mnesia, sasl]),
    %% DB
    %% ok = mnesia:create_schema([node()]),
    etorrent_mnesia_init:init(),
    etorrent_mnesia_init:wait(),
    %% Etorrent
    application:start(etorrent, permanent).

%% @doc Application callback.
%% @end
start(_Type, _Args) ->
    PeerId = generate_peer_id(),
    etorrent_sup:start_link(PeerId).

%% @doc Application callback.
%% @end
stop() ->
    ok = application:stop(etorrent).

%% @doc Application callback.
%% @end
prep_stop(_S) ->
    io:format("Shutting down etorrent~n"),
    ok.

%% @doc Application callback.
%% @end
stop(_State) ->
    ok.

%% @doc List currently active torrents.
%% <p>This function will list the torrent files which are currently in
%% the active state in the etorrent system. A general breakdown of each
%% torrent and its current states is given. The function is given as a
%% convenience in the shell while the system is running.</p>
%% @end
-spec list() -> ok.
list() ->
    A = etorrent_torrent:all(),
    {DownloadRate, UploadRate} = etorrent_rate_mgr:global_rate(),
    io:format("~3s ~11s ~11s ~11s ~11s ~3s ~3s ~7s~n",
              ["Id:", "total", "left", "uploaded", "downloaded",
               "I", "C", "Comp."]),

    lists:foreach(
      fun (R) ->
          {DaysLeft, {HoursLeft, MinutesLeft, SecondsLeft}} =
            etorrent_rate:eta(R#torrent.left, DownloadRate),
              {atomic, [#tracking_map { filename = FN, _=_}]} =
                  etorrent_tracking_map:select(R#torrent.id),
              io:format("~3.B ~11.B ~11.B ~11.B ~11.B ~3.B ~3.B ~7.3f% ETA: ~Bd ~Bh ~Bm ~Bs ~n",
                        [R#torrent.id,
                         R#torrent.total,
                         R#torrent.left,
                         R#torrent.uploaded,
                         R#torrent.downloaded,
                         R#torrent.leechers,
                         R#torrent.seeders,
                         percent_complete(R),
             DaysLeft, HoursLeft, MinutesLeft, SecondsLeft]),
              io:format("    ~s~n", [FN])
                  end, A),
    %io:format("Rate Up/Down: ~e / ~e~n", [UploadRate, DownloadRate]).
    io:format("Rate Up/Down: ~8.2f / ~8.2f~n", [UploadRate / 1024.0,
                                                DownloadRate / 1024.0]).

%% @doc Show detailed information for Item.
%% @end
show() ->
    io:format("You must supply a torrent Id number~n").

%% @doc Show detailed information for Item.
%% @end
show(Item) when is_integer(Item) ->
    %{atomic, Torrent} = etorrent_torrent:select(Item),
    case etorrent_tracking_map:select(Item) of
        {atomic, [R]} ->
            io:format("Id: ~3.B Name: ~s~n",
                      [R#tracking_map.id, R#tracking_map.filename]);
        {atomic, []} ->
            io:format("No such torrent Id~n")
    end;
show(_) ->
    io:format("Item supplied is not an integer~n").

%% @doc Check a torrents contents. For debugging.
%% @end
check(Id) ->
    etorrent_mgr:check(Id).

%% @doc Provide a simple help message for the commands supported.
%% <p>This function will output a simple help message for the usage of the
%% CLI to etorrent.</p>
%% @end
help() ->
    io:format("Available commands:~n", []),

    Commands = [{"help, h", "This help"},
                {"list, l", "List torrents in system"},
                {"show, s", "Show detailed information for a given torrent"},
                {"stop", "Stop the system"}],

    lists:foreach(fun({Command, Desc}) ->
                          io:format("~-12.s - ~s~n", [Command, Desc])
                  end,
                  Commands),
    ok.

%%--------------------------------------------------------------------
h() -> help().
l() -> list().
s() -> show().
s(Item) -> show(Item).

%%=====================================================================
percent_complete(R) ->
    %% left / complete * 100 = % done
    (R#torrent.total - R#torrent.left) / R#torrent.total * 100.

%% @doc Generate a random peer id for use
%% @end
generate_peer_id() ->
    Number = crypto:rand_uniform(0, ?RANDOM_MAX_SIZE),
    Rand = io_lib:fwrite("~B----------", [Number]),
    lists:flatten(io_lib:format("-ET~s-~12s", [?VERSION, Rand])).
