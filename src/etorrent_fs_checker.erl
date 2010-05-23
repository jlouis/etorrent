%%%-------------------------------------------------------------------
%%% File    : check_torrent.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus.local.domain>
%%% License : See COPYING
%%% Description : Code for checking the correctness of a torrent file map
%%%
%%% Created :  6 Jul 2007 by Jesper Louis Andersen <jlouis@succubus.local.domain>
%%%-------------------------------------------------------------------
-module(etorrent_fs_checker).

-include("etorrent_piece.hrl").

%% API
-export([read_and_check_torrent/3, check_torrent/2]).

%%====================================================================
%% API
%%====================================================================

%% Check the contents of torrent Id, backed by filesystem FS and report a
%%   list of bad pieces.
check_torrent(FS, Id) ->
    Pieces = etorrent_piece_mgr:select(Id),
    PieceCheck =
        fun (#piece { idpn = {_, PN}, hash = Hash}) ->
                {ok, Data} = etorrent_fs:read_piece(FS, PN),
                Hash =/= crypto:sha(Data)
        end,
    [P#piece.idpn || P <- Pieces,
                     PieceCheck(P)].

initialize_dictionary(Id, Path) ->
    %% Load the torrent
    {ok, Torrent, Files, IH} = load_torrent(Path),
    ok = ensure_file_sizes_correct(Files),
    {ok, FPList, NumPieces} = build_dictionary_on_files(Id, Torrent, Files),
    {ok, Torrent, IH, FPList, NumPieces}.

read_and_check_torrent(Id, SupervisorPid, Path) ->
    {ok, Torrent, Infohash, FilePieceList, NumberOfPieces} =
        initialize_dictionary(Id, Path),

    %% Check the contents of the torrent, updates the state of the piecemap
    FS = etorrent_t_sup:get_pid(SupervisorPid, fs),
    case etorrent_fast_resume:query_state(Id) of
        seeding -> initialize_pieces_seed(Id, FilePieceList);
        {bitfield, BF} -> initialize_pieces_from_bitfield(Id, BF, NumberOfPieces, FilePieceList);
        leeching ->
            ok = etorrent_piece_mgr:add_pieces(
                   Id,
                  [{PN, Hash, Fls, not_fetched} || {PN, {Hash, Fls}} <- FilePieceList]),
            ok = initialize_pieces_from_disk(FS, Id, FilePieceList);
        %% XXX: The next one here could initialize with not_fetched all over
        unknown ->
            ok = etorrent_piece_mgr:add_pieces(
                   Id,
                  [{PN, Hash, Fls, not_fetched} || {PN, {Hash, Fls}} <- FilePieceList]),
            ok = initialize_pieces_from_disk(FS, Id, FilePieceList)
    end,

    {ok, Torrent, FS, Infohash, NumberOfPieces}.

load_torrent(Path) ->
    {ok, Workdir} = application:get_env(etorrent, dir),
    P = filename:join([Workdir, Path]),
    Torrent = etorrent_bcoding:parse(P),
    Files = etorrent_metainfo:get_files(Torrent),
    Name = etorrent_metainfo:get_name(Torrent),
    InfoHash = etorrent_metainfo:get_infohash(Torrent),
    FilesToCheck =
        [{filename:join([Name, Filename]), Size} ||
            {Filename, Size} <- Files],
    {ok, Torrent, FilesToCheck, InfoHash}.

ensure_file_sizes_correct(Files) ->
    {ok, Workdir} = application:get_env(etorrent, dir),
    lists:foreach(
      fun ({Pth, ISz}) ->
              F = filename:join([Workdir, Pth]),
              Sz = filelib:file_size(F),
              case Sz == ISz of
                  true ->
                      ok;
                  false ->
                      Missing = ISz - Sz,
                      fill_file_ensure_path(F, Missing)
              end
      end,
      Files),
    ok.

initialize_pieces_seed(Id, FilePieceList) ->
    etorrent_piece_mgr:add_pieces(
      Id,
      [{PN, Hash, Files, fetched} || {PN, {Hash, Files}} <- FilePieceList]).

initialize_pieces_from_bitfield(Id, BitField, NumPieces, FilePieceList) ->
    {ok, Set} = etorrent_proto_wire:decode_bitfield(NumPieces, BitField),
    F = fun (PN) ->
                case gb_sets:is_element(PN, Set) of
                    true -> fetched;
                    false -> not_fetched
                end
        end,
    Pieces = [{PN, Hash, Files, F(PN)} || {PN, {Hash, Files}} <- FilePieceList],
    etorrent_piece_mgr:add_pieces(Id, Pieces).

initialize_pieces_from_disk(FS, Id, FilePieceList) ->
    F = fun(PN, Hash, Files) ->
                {ok, Data} = etorrent_fs:read_piece(FS, PN),
                State = case Hash =:= crypto:sha(Data) of
                            true -> fetched;
                            false -> not_fetched
                        end,
                {PN, Hash, Files, State}
        end,
    etorrent_piece_mgr:add_pieces(
      Id,
      [F(PN, Hash, Files) || {PN, {Hash, Files}} <- FilePieceList]).

build_dictionary_on_files(TorrentId, Torrent, Files) ->
    Pieces = etorrent_metainfo:get_pieces(Torrent),
    PSize = etorrent_metainfo:get_piece_length(Torrent),
    LastPieceSize = lists:sum([S || {_F, S} <- Files]) rem PSize,
    {ok, PieceList, N} = construct_fpmap(Files, 0, PSize, LastPieceSize,
                                         lists:zip(lists:seq(0, length(Pieces)-1), Pieces),
                                         [], 0),
    MappedPieces = [{Num, {Hash, insert_into_path_map(Ops, TorrentId)}} ||
                       {Num, {Hash, Ops}} <- PieceList],
    {ok, MappedPieces, N}.

%%====================================================================
%% Internal functions
%%====================================================================

extract_piece(0, Fs, Offset, B) ->
    {ok, Fs, Offset, B};
extract_piece(Left, [], _O, _Building) ->
    {error_need_files, Left};
extract_piece(Left, [{Pth, Sz} | R], Offset, Building) ->
    case (Sz - Offset) > Left of
        true ->
            % There is enough bytes left in Pth
            {ok, [{Pth, Sz} | R], Offset+Left,
             [{Pth, Offset, Left} | Building]};
        false ->
            % There is not enough space left in Pth
            BytesWeCanGet = Sz - Offset,
            extract_piece(Left - BytesWeCanGet, R, 0,
                          [{Pth, Offset, BytesWeCanGet} | Building])
    end.

construct_fpmap([], _Offset, _PieceSize, _LPS, [], Done, N) ->
    {ok, Done, N};
construct_fpmap([], _O, _P, _LPS, _Pieces, _D, _N) ->
    error_more_pieces;
construct_fpmap(FileList, Offset, PieceSize, LastPieceSize,
                [{Num, Hash}], Done, N) -> % Last piece
    {ok, FL, OS, Ops} = extract_piece(case LastPieceSize of
                                          0 -> PieceSize;
                                          K -> K
                                      end,
                                      FileList, Offset, []),
    construct_fpmap(FL, OS, PieceSize, LastPieceSize, [],
                    [{Num, {Hash, lists:reverse(Ops)}} | Done], N+1);
construct_fpmap(FileList, Offset, PieceSize, LastPieceSize,
                [{Num, Hash} | Ps], Done, N) ->
    {ok, FL, OS, Ops} = extract_piece(PieceSize, FileList, Offset, []),
    construct_fpmap(FL, OS, PieceSize, LastPieceSize, Ps,
                    [{Num, {Hash, lists:reverse(Ops)}} | Done], N+1).

insert_into_path_map(Ops, TorrentId) ->
    insert_into_path_map(Ops, TorrentId, none, none).

insert_into_path_map([], _, _, _) -> [];
insert_into_path_map([{Path, Offset, Size} | Next], TorrentId, Path, Keyval) ->
    [{Keyval, Offset, Size} | insert_into_path_map(Next, TorrentId, Path, Keyval)];
insert_into_path_map([{Path, Offset, Size} | Next], TorrentId, _Key, _KeyVal) ->
    KeyVal = etorrent_path_map:select(Path, TorrentId),
    [{KeyVal, Offset, Size} | insert_into_path_map(Next, TorrentId, Path, KeyVal)].


fill_file_ensure_path(Path, Missing) ->
    case file:open(Path, [read, write, delayed_write, binary, raw]) of
        {ok, FD} ->
            fill_file(FD, Missing);
        {error, enoent} ->
            % File missing
            ok = filelib:ensure_dir(Path),
            case file:open(Path, [read, write, delayed_write, binary, raw]) of
                {ok, FD} ->
                    fill_file(FD, Missing);
                {error, Reason} ->
                    {error, Reason}
            end
    end.

fill_file(FD, Missing) ->
    {ok, _NP} = file:position(FD, {eof, Missing-1}),
    file:write(FD, <<0>>),
    file:close(FD).
