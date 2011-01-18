%%%-------------------------------------------------------------------
%%% File    : check_torrent.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus.local.domain>
%%% License : See COPYING
%%% Description : Code for checking the correctness of a torrent file map
%%%
%%% Created :  6 Jul 2007 by Jesper Louis Andersen <jlouis@succubus.local.domain>
%%%-------------------------------------------------------------------
-module(etorrent_fs_checker).

-include("types.hrl").

%% API
-export([read_and_check_torrent/2, check_torrent/1, check_piece/2]).

%% ====================================================================

% @doc Check the contents of torrent Id
% <p>We will check a torrent, Id, and report a list of bad pieces.</p>
% @end
-spec check_torrent(integer()) -> [pos_integer()].
check_torrent(Id) ->
    PieceHashes = etorrent_piece_mgr:piecehashes(Id),
    PieceCheck =
        fun (PN, Hash) ->
                {ok, Data} = etorrent_io:read_piece(Id, PN),
                Hash =/= crypto:sha(Data)
        end,
    [PN || {PN, Hash} <- PieceHashes,
	   PieceCheck(PN, Hash)].

% @doc Read and check a torrent
% <p>The torrent given by Id, at Path (the .torrent file) will be checked for
%  correctness. We return a tuple
%  with various information about said torrent: The decoded Torrent dictionary,
%  the info hash and the number of pieces in the torrent.</p>
% @end
-spec read_and_check_torrent(integer(), string()) -> {ok, bcode(), binary(), integer()}.
read_and_check_torrent(Id, Path) ->
    {ok, Torrent, Infohash, FilePieceList, NumberOfPieces} =
        initialize_dictionary(Id, Path),

    %% Check the contents of the torrent, updates the state of the piecemap
    FS = gproc:lookup_local_name({torrent, Id, fs}),
    case etorrent_fast_resume:query_state(Id) of
	{value, PL} ->
	    case proplists:get_value(state, PL) of
		seeding -> initialize_pieces_seed(Id, FilePieceList);
		{bitfield, BF} ->
		    initialize_pieces_from_bitfield(Id, BF,
						    NumberOfPieces, FilePieceList)
	    end;
        %% XXX: The next one here could initialize with not_fetched all over
        unknown ->
            ok = etorrent_piece_mgr:add_pieces(
                   Id,
                  [{PN, Hash, Fls, not_fetched} || {PN, {Hash, Fls}} <- FilePieceList]),
            ok = initialize_pieces_from_disk(FS, Id, FilePieceList)
    end,

    {ok, Torrent, Infohash, NumberOfPieces}.

%% @doc Search the mnesia tables for the Piece with Index and
%%      write it back to disk.
%% @end
-spec check_piece(torrent_id(), integer()) -> ok.
check_piece(TorrentID, PieceIndex) ->
    InfoHash = etorrent_piece_mgr:piece_hash(TorrentID, PieceIndex),
    {ok, PieceBin} = etorrent_io:read_piece(TorrentID, PieceIndex),
    PieceSize = byte_size(PieceBin),
    case crypto:sha(PieceBin) == InfoHash of
        true ->
            ok = etorrent_torrent:statechange(TorrentID, [{subtract_left, PieceSize}]),
            ok = etorrent_piece_mgr:statechange(TorrentID, PieceIndex, fetched),
            _  = etorrent_table:foreach_peer(TorrentID,
                     fun(Pid) -> etorrent_peer_control:have(Pid, PieceIndex) end),
            ok;
        _ ->
            ok = etorrent_piece_mgr:statechange(TorrentID, PieceIndex, not_fetched)
    end.

%% =======================================================================

initialize_dictionary(Id, Path) ->
    %% Load the torrent
    {ok, Torrent, Files, IH} = load_torrent(Path),
    ok = ensure_file_sizes_correct(Files),
    {ok, FPList, NumPieces} = build_dictionary_on_files(Id, Torrent, Files),
    {ok, Torrent, IH, FPList, NumPieces}.

load_torrent(Path) ->
    Workdir = etorrent_config:work_dir(),
    P = filename:join([Workdir, Path]),
    {ok, Torrent} = etorrent_bcoding:parse_file(P),
    Files = etorrent_metainfo:get_files(Torrent),
    Name = etorrent_metainfo:get_name(Torrent),
    InfoHash = etorrent_metainfo:get_infohash(Torrent),
    FilesToCheck =
	case Files of
	    [_] -> Files;
	    [_|_] ->
		[{filename:join([Name, Filename]), Size}
		 || {Filename, Size} <- Files]
	end,
    {ok, Torrent, FilesToCheck, InfoHash}.

ensure_file_sizes_correct(Files) ->
    Dldir = etorrent_config:download_dir(),
    lists:foreach(
      fun ({Pth, ISz}) ->
              F = filename:join([Dldir, Pth]),
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

initialize_pieces_from_disk(_, Id, FilePieceList) ->
    F = fun(PN, Hash, Files) ->
                {ok, Data} = etorrent_io:read_piece(Id, PN),
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
    {value, KeyVal} = etorrent_table:insert_path(Path, TorrentId),
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
    case application:get_env(etorrent, preallocation_strategy) of
	undefined -> fill_file_sparse(FD, Missing);
	{ok, sparse} -> fill_file_sparse(FD, Missing);
	{ok, preallocate} -> fill_file_prealloc(FD, Missing)
    end.

fill_file_sparse(FD, Missing) ->
    {ok, _NP} = file:position(FD, {eof, Missing-1}),
    ok = file:write(FD, <<0>>),
    ok = file:close(FD).

fill_file_prealloc(FD, N) ->
    {ok, _NP} = file:position(FD, eof),
    SZ4 = N div 4,
    Rem = (N rem 4) * 8,
    create_file(FD, 0, SZ4),
    ok = file:write(FD, <<0:Rem/unsigned>>).

create_file(_FD, M, M) ->
           ok;
create_file(FD, M, N) when M + 1024 =< N ->
    create_file(FD, M, M + 1024, []),
    create_file(FD, M + 1024, N);
create_file(FD, M, N) ->
    create_file(FD, M, N, []).

create_file(FD, M, M, R) ->
    ok = file:write(FD, R);
create_file(FD, M, N0, R) when M + 8 =< N0 ->
    N1  = N0-1,  N2  = N0-2,  N3  = N0-3,  N4  = N0-4,
    N5  = N0-5,  N6  = N0-6,  N7  = N0-7,  N8  = N0-8,
    create_file(FD, M, N8,
		[<<N8:32/unsigned,  N7:32/unsigned,
		   N6:32/unsigned,  N5:32/unsigned,
		   N4:32/unsigned,  N3:32/unsigned,
		   N2:32/unsigned,  N1:32/unsigned>> | R]);
create_file(FD, M, N0, R) ->
    N1 = N0-1,
    create_file(FD, M, N1, [<<N1:32/unsigned>> | R]).
