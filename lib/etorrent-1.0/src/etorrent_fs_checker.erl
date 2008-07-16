%%%-------------------------------------------------------------------
%%% File    : check_torrent.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus.local.domain>
%%% License : See COPYING
%%% Description : Code for checking the correctness of a torrent file map
%%%
%%% Created :  6 Jul 2007 by Jesper Louis Andersen <jlouis@succubus.local.domain>
%%%-------------------------------------------------------------------
-module(etorrent_fs_checker).

-include("etorrent_mnesia_table.hrl").

%% API
-export([read_and_check_torrent/3, load_torrent/1, ensure_file_sizes_correct/1,
	 check_torrent_contents/2]).

-define(DEFAULT_CHECK_SLEEP_TIME, 10).

%%====================================================================
%% API
%%====================================================================

read_and_check_torrent(Id, SupervisorPid, Path) ->
    %% Load the torrent
    {ok, Torrent, Files, Infohash} =
	load_torrent(Path),

    %% Ensure the files are filled up with garbage of correct size
    ok = ensure_file_sizes_correct(Files),

    %% Build the dictionary mapping pieces to file operations
    {ok, FileDict, NumberOfPieces} =
	build_dictionary_on_files(Id, Torrent, Files),

    %% Initialize piecemap
    _Dict = etorrent_piece:new(Id, FileDict),

    %% Check the contents of the torrent, updates the state of the piecemap
    FS = etorrent_t_sup:get_pid(SupervisorPid, fs),
    case etorrent_fast_resume:query_state(Id) of
	seeding -> check_torrent_contents_seed(Id);
	{bitfield, BF} -> check_torrent_contents_bitfield(Id, BF, NumberOfPieces);
	leeching -> ok = check_torrent_contents(FS, Id);
	%% XXX: The next one here could initialize with not_fetched all over
	unknown -> ok = check_torrent_contents(FS, Id)
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

check_torrent_contents_seed(Id) ->
    {atomic, Pieces} = etorrent_piece:select(Id),
    lists:foreach(
      fun(#piece { piece_number = PN }) ->
	      {atomic, _} = etorrent_piece:statechange(Id, PN, fetched)
      end,
      Pieces),
    ok.

check_torrent_contents_bitfield(Id, BitField, NumPieces) ->
    {atomic, Pieces} = etorrent_piece:select(Id),
    {ok, Set} = etorrent_peer_communication:destruct_bitfield(NumPieces, BitField),
    lists:foreach(
      fun(#piece { piece_number = PN }) ->
	      State = case gb_sets:is_element(PN, Set) of
			  true -> fetched;
			  false -> not_fetched
		      end,
	      {atomic, _} = etorrent_piece:statechange(Id, PN, State)
      end,
      Pieces),
    ok.

check_torrent_contents(FS, Id) ->
    {atomic, Pieces} = etorrent_piece:select(Id),
    lists:foreach(
      fun(#piece{piece_number = PieceNum, hash = Hash}) ->
	      {ok, Data} = etorrent_fs:read_piece(FS, PieceNum),
	      State =
		  case Hash =:= crypto:sha(Data) of
		      true ->
			  fetched;
		      false ->
			  not_fetched
		  end,
	      {atomic, _} = etorrent_piece:statechange(Id, PieceNum, State),
	      timer:sleep(?DEFAULT_CHECK_SLEEP_TIME)
      end,
      Pieces),
    ok.

build_dictionary_on_files(TorrentId, Torrent, Files) ->
    Pieces = etorrent_metainfo:get_pieces(Torrent),
    PSize = etorrent_metainfo:get_piece_length(Torrent),
    LastPieceSize = lists:sum([S || {_F, S} <- Files]) rem PSize,
    {ok, PieceList, N} = construct_fpmap(Files, 0, PSize, LastPieceSize,
					 lists:zip(lists:seq(0, length(Pieces)-1), Pieces),
					 [], 0),
    MappedPieces = [{Num, {Hash, insert_into_piece_map(Ops, TorrentId), X}} ||
		       {Num, {Hash, Ops, X}} <- PieceList],
    {ok, dict:from_list(MappedPieces), N}.

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
    {ok, FL, OS, Ops} = extract_piece(LastPieceSize, FileList, Offset, []),
    construct_fpmap(FL, OS, PieceSize, LastPieceSize, [],
		    [{Num, {Hash, lists:reverse(Ops), none}} | Done], N+1);
construct_fpmap(FileList, Offset, PieceSize, LastPieceSize,
		[{Num, Hash} | Ps], Done, N) ->
    {ok, FL, OS, Ops} = extract_piece(PieceSize, FileList, Offset, []),
    construct_fpmap(FL, OS, PieceSize, LastPieceSize, Ps,
		    [{Num, {Hash, lists:reverse(Ops), none}} | Done], N+1).

insert_into_piece_map(Ops, TorrentId) ->
    [{etorrent_path_map:select(Path, TorrentId), Offset, Size} ||
	{Path, Offset, Size} <- Ops].

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
