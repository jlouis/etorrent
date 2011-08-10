-module(etorrent_dotfiles).
%% @doc Functions to access the .etorrent directory.
%% @end

%% exported functions
-export([torrents/0]).

%% @doc List all available torrent files.
%% @end
-spec torrents() -> [Filenames::string()].
torrents() ->
    [].

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

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
        fun(_) -> application:stop(gproc) end,
    {foreach, local,
        fun setup_config/0,
        fun teardown_config/1, [
    ?_test(test_no_torrents())
    ]}}.

test_no_torrents() ->
    ?assertEqual([], ?MODULE:torrents()).

-endif.
