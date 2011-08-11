-module(etorrent_dotfiles).
%% @doc Functions to access the .etorrent directory.
%% @end

%% exported functions
-export([make/0,
         torrents/0,
         copy_torrent/1,
         copy_path/1,
         info_path/1,
         info_hash/1,
         read_info/1,
         write_info/2]).

%% private functions
-export([exists/1]).

%% include files
-include_lib("kernel/include/file.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% types
-type bencode() :: etorrent_types:bencode().

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
%% The torrent files are identified by their info hashes. This is more
%% correct than trusting that all torrent files has been assigned a unique
%% filename.
%% @end
-spec torrents() -> {ok, [Filenames::string()]} | {error, noent}.
torrents() ->
    case file:list_dir(dotdir()) of
        {ok, Files} ->
            IsTorrent = fun(Str) -> lists:suffix(".torrent", Str) end,
            Basename = fun(Str) -> filename:basename(Str, ".torrent") end,
            Torrents = [Basename(I) || I <- Files, IsTorrent(I)],
            %% @todo filter out files whose basename does not appear to
            %% to be a valid hex encoded info hash?
            {ok, Torrents};
        {error, _}=Error ->
            Error
    end.

%% @doc Make a private copy of a torrent file.
%% The torrent file is copied to $DOTDIR/$INFOHASH.torrent. After a copy
%% of the torrent file has been made it is safe to delete the original file.
%% @end
-spec copy_torrent(Torrentfile::string()) -> ok.
copy_torrent(Torrentfile) when is_list(Torrentfile) ->
    case info_hash(Torrentfile) of
        {error, _}=Error ->
            Error;
        {ok, Infohash} ->
            Dest = copy_path(Infohash),
            case file:copy(Torrentfile, Dest) of
                {error, _}=Error -> Error;
                {ok, _} -> {ok, Infohash}
            end
    end.

-spec copy_path(Infohash::binary()) -> Torrentpath::string().
copy_path(Infohash) ->
    base_path(Infohash) ++ ".torrent".

%% @doc Get the path of the info file for a torrent.
%% A corresponding .info file is created to each .torrent file that is
%% started. The .info file contains a snapshot of the running state of
%% a torrent.
%% @end
-spec info_path(Infohash::binary()) -> Infopath::string().
info_path(Infohash) ->
    base_path(Infohash) ++ ".info".

%% @doc Return an incomplete path into the .etorrent directory.
%% The path should be unique for each torrent. copy_path/1 and
%% info_path/1 exists to add an extension to this path.
%% @end
-spec base_path(Infohash::binary()) -> Path::string().
base_path(Infohash) ->
    assert_hex_hash(Infohash),
    filename:join([dotdir(), Infohash]).


%% @doc Get the info hash of a torrent file.
%% @end
-spec info_hash(Torrentfile::string()) -> {ok, [byte()]} | {error, _}.
info_hash(Torrentfile) ->
    case file:read_file(Torrentfile) of
        {ok, Bin} ->
            {ok, Terms} = etorrent_bcoding:decode(Bin),
            Infohash = etorrent_metainfo:get_infohash(Terms),
            {ok, info_hash_to_hex(Infohash)};
        {error, _}=Error ->
            Error
    end.

%% @private
info_hash_to_hex(<<Infohash:20/binary>>) ->
    ToHex = fun(I) -> string:to_lower(integer_to_list(I, 16)) end,
    HexIO = [ToHex(I) || <<I>> <= Infohash],
    lists:flatten(HexIO).

%% @private
assert_hex_hash(Infohash) ->
    length(Infohash) =:= 40 orelse erlang:error(badlength),
    IsHex = fun
        (C) when C >= $0, C =< $9 -> true;
        (C) when C >= $a, C =< $f -> true;
        (_) -> false
    end,
    lists:all(IsHex, Infohash) orelse erlang:error(badhex).
    
    

%% @todo Make caller provide a default value to return if {error, enoent}?
-spec read_info(binary()) -> {ok, bencode()} | {error, atom()}.
read_info(Infohash) ->
    File = info_path(Infohash),
    etorrent_bcoding:parse_file(File).

%% @todo No synchronization. This function is expected to be called periodically
%% from a single process to write a complete copy of the state. (by the process
%% that is authorative on this information).
-spec write_info(binary(), bencode()) -> ok | {error, atom()}.
write_info(Infohash, Data) ->
    Bin = etorrent_bcoding:encode(Data),
    File = info_path(Infohash),
    file:write_file(File, Bin).

    

%% @private Check if a file path exists.
%% XXX: Make separate assertion on the filetype.
-spec exists(Path::string()) -> boolean().
exists(Path) ->
    case file:read_file_info(Path) of
        {ok, _} -> true;
        {error, _} -> false
    end.

%% @private
dotdir() -> gproc:get_env(l, etorrent, dotdir).
        
        

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

testpath() ->
    "../../../test/etorrent_eunit_SUITE_data/debian-6.0.2.1-amd64-netinst.iso.torrent".

testfile() ->
    "debian-6.0.2.1-amd64-netinst.iso.torrent".

testhash() ->
    <<142,215,218,181,31,70,216,236,194,208,141,204,28,28,160,136,237,138,83,180>>.

testhex()  -> "8ed7dab51f46d8ecc2d08dcc1c1ca088ed8a53b4".
testcopy() -> "8ed7dab51f46d8ecc2d08dcc1c1ca088ed8a53b4.torrent".
testinfo() -> "8ed7dab51f46d8ecc2d08dcc1c1ca088ed8a53b4.info".




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
                ?_test(test_copy_torrent()),
                ?_test(test_info_filename()),
                ?_test(test_info_hash())
            ]}
        ]}
    ]}.

test_no_torrents() ->
    ?assertEqual({error, enoent}, ?MODULE:torrents()).

test_ensure_exists() ->
    ?assertNot(?MODULE:exists(dotdir())),
    ok = ?MODULE:make(),
    ?assert(?MODULE:exists(dotdir())).

test_hex_infohash() ->
    ?assertEqual({ok, testhex()}, ?MODULE:hex_info_hash(testhash())).

test_copy_torrent() ->
    ?assertEqual({ok, testhex()}, ?MODULE:copy_torrent(testpath())),
    ?assertEqual({ok, [testhex()]}, ?MODULE:torrents()).

test_info_filename() ->
    {ok, Infohash} = ?MODULE:copy_torrent(testpath()),
    ?assertEqual(testinfo(), lists:last(filename:split(?MODULE:info_path(Infohash)))).

test_info_hash() ->
    ?assertEqual({ok, testhex()}, ?MODULE:info_hash(testpath())).

-endif.
