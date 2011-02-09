%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Etorrent Command line interface
%% <p>This module implements the CLI of etorrent. It is the intended
%% entry-point for a human  being to query etorrent for what it is
%% doing right now. A number of commands exist, which can be asked for
%% with the help/0 call. From there the rest of the commands can be
%% perused.</p>
%% @end
-module(etorrent).

%% API
%% Query
-export([help/0, h/0, list/0, l/0, show/0, s/0, show/1, s/1, check/1]).

%% Etorrent-as-library
-export([start/1]).

-ignore_xref([{h, 0}, {l, 0}, {s, 0}, {s, 1}, {check, 1},
	      {help, 0}, {list, 0}, {show, 0}, {show, 1}]).

%%====================================================================

%% @doc List currently active torrents.
%% <p>This function will list the torrent files which are currently in
%% the active state in the etorrent system. A general breakdown of each
%% torrent and its current states is given. The function is given as a
%% convenience in the shell while the system is running.</p>
%% @end
-spec list() -> ok.
list() ->
    All = etorrent_torrent:all(),
    A   = lists:sort(
	    fun(PL1, PL2) ->
		    proplists:get_value(id, PL1) =< proplists:get_value(id, PL2)
	    end,
	    All),
    {DownloadRate, UploadRate} = etorrent_peer_states:get_global_rate(),
    io:format("~3s ~11s ~11s ~11s ~11s ~3s ~3s ~7s~n",
              ["Id:", "total", "left", "uploaded", "downloaded",
               "I", "C", "Comp."]),

    lists:foreach(
      fun (R) ->
	      Eta = etorrent_rate:format_eta(proplists:get_value(left, R),
					     DownloadRate),
	      Uploaded = proplists:get_value(uploaded, R) +
			 proplists:get_value(all_time_uploaded, R),
	      Downloaded = proplists:get_value(downloaded, R) +
		           proplists:get_value(all_time_downloaded, R),
	      {value, PL} = etorrent_table:get_torrent(proplists:get_value(id, R)),
              io:format("~3.B ~11.B ~11.B ~11.B ~11.B ~3.B ~3.B ~7.3f% ~s ~n",
                        [proplists:get_value(id, R),
			 proplists:get_value(total, R),
			 proplists:get_value(left, R),
			 Uploaded,
			 Downloaded,
			 proplists:get_value(leechers, R),
			 proplists:get_value(seeders, R),
                         percent_complete(R),
			 Eta]),
              io:format("    ~s~n", [proplists:get_value(filename, PL)])
      end, A),
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
    case etorrent_table:get_torrent(Item) of
        {value, PL} ->
            io:format("Id: ~3.B Name: ~s~n",
                      [proplists:get_value(id, PL),
		       proplists:get_value(filename, PL)]);
        not_found ->
            io:format("No such torrent Id~n")
    end;
show(_) ->
    io:format("Item supplied is not an integer~n").

%% @doc Check a torrents contents. For debugging.
%% @end
check(Id) ->
    etorrent_ctl:check(Id).

%% @doc Provide a simple help message for the commands supported.
%% <p>This function will output a simple help message for the usage of the
%% CLI to etorrent.</p>
%% @end
help() ->
    io:format("Available commands:~n", []),

    Commands = [{"help, h", "This help"},
                {"list, l", "List torrents in system"},
                {"show, s", "Show detailed information for a given torrent"},
                {"stop", "Stop the system"},
	        {"start(File)", "Start the given file as a .torrent"}],

    lists:foreach(fun({Command, Desc}) ->
                          io:format("~-12.s - ~s~n", [Command, Desc])
                  end,
                  Commands),
    ok.

%%--------------------------------------------------------------------
%% @equiv help()
h() -> help().
%% @equiv list()
l() -> list().
%% @equiv show()
s() -> show().
%% @equiv show(Item)
s(Item) -> show(Item).

start(Filename) when is_list(Filename) ->
    etorrent_ctl:start(Filename).

%%=====================================================================
%% @todo Move this function (and its webui friend) to etorrent_torrent.
percent_complete(R) ->
    %% left / complete * 100 = % done
    T = proplists:get_value(total, R),
    L = proplists:get_value(left, R),
    (T - L) / T * 100.

