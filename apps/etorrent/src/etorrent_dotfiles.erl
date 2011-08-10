-module(etorrent_dotfiles).
%% @doc Functions to access the .etorrent directory.
%% @end

%% exported functions
-export([make/0,
         torrents/0,
         copy/1]).

%% private functions
-export([exists/1]).

%% include files
-include_lib("kernel/include/file.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% @doc Ensure that the dotfile directory exists.
%% @end
-spec make() -> ok.
make() ->
    Dir = gproc:get_env(l, etorrent, dotdir),
    case exists(Dir) of
        true -> ok;
        false -> make_(Dir)
    end.

make_(Dir) ->
    file:make_dir(Dir).

%% @doc List all available torrent files.
%% @end
-spec torrents() -> {ok, [Filenames::string()]} | {error, noent}.
torrents() ->
    file:list_dir(gproc:get_env(l, etorrent, dotdir)).

%% @doc Make a private copy of a torrent file.
%% @end
-spec copy(Torrentfile::string()) -> ok.
copy(Torrentfile) when is_list(Torrentfile) ->
    File = filename:basename(Torrentfile),
    Dotdir = gproc:get_env(l, etorrent, dotdir),
    Dest = filename:join([Dotdir, File]),
    case file:copy(Torrentfile, Dest) of
        {ok, _} -> ok;
        {error, _}=Error -> Error
    end.

%% @private Check if a file path exists.
-spec exists(Path::string()) -> boolean().
exists(Path) ->
    case file:read_file_info(Path) of
        {ok, _} -> true;
        {error, _} -> false
    end.
        
        

-ifdef(TEST).

%% @private Update dotdir configuration parameter to point to a new directory.
setup_config() ->
    Dir = test_server:temp_name("/tmp/etorrent."),
    gproc:get_set_env(l, etorrent, dotdir, [{default, Dir}]),
    Dir.

%% @private Delete the directory pointed to by the dotdir configuration parameter.
teardown_config(_Dir) ->
    %% @todo Recursive file:delete.
    ok.


dotfiles_test_() ->
    {setup,local,
        fun() -> application:start(gproc) end,
        fun(_) -> application:stop(gproc) end, [
        {foreach,local,
            fun setup_config/0,
            fun teardown_config/1, [
            ?_test(test_no_torrents()),
            ?_test(test_ensure_exists()),
            {setup,local,
                fun() -> ?MODULE:make() end,
                fun(_) -> ok end, [
                ?_test(test_copy_torrent())
            ]}
        ]}
    ]}.

test_no_torrents() ->
    ?assertEqual({error, enoent}, ?MODULE:torrents()).

test_ensure_exists() ->
    ?assertNot(?MODULE:exists(gproc:get_env(l, etorrent, dotdir))),
    ok = ?MODULE:make(),
    ?assert(?MODULE:exists(gproc:get_env(l, etorrent, dotdir))).

test_copy_torrent() ->
    Torrent = "../../../test/etorrent_eunit_SUITE_data/debian-6.0.2.1-amd64-netinst.iso.torrent",
    ok = ?MODULE:copy(Torrent),
    ?assertEqual({ok, ["debian-6.0.2.1-amd64-netinst.iso.torrent"]}, ?MODULE:torrents()).

-endif.
