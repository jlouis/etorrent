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
-export([read_and_check_torrent/4, load_torrent/2, ensure_file_sizes_correct/1,
	build_dictionary_on_files/2, check_torrent_contents/2]).

%%====================================================================
%% API
%%====================================================================

read_and_check_torrent(Id, SupervisorPid, WorkDir, Path) ->
    %% Load the torrent
    {ok, Torrent, Files, Infohash} =
	load_torrent(WorkDir, Path),

    %% Ensure the files are filled up with garbage of correct size
    ok = ensure_file_sizes_correct(Files),

    %% Build the dictionary mapping pieces to file operations
    {ok, FileDict, NumberOfPieces} =
	build_dictionary_on_files(Torrent, Files),

    %% Initialize the filesystem, initializes the piecemap
    {ok, FS} = add_filesystem(Id, SupervisorPid, FileDict),

    %% Check the contents of the torrent, updates the state of the piecemap
    ok = etorrent_fs_checker:check_torrent_contents(FS, Id),

    {ok, Torrent, FS, Infohash, NumberOfPieces}.

load_torrent(Workdir, Path) ->
    P = filename:join([Workdir, Path]),
    Torrent = etorrent_bcoding:parse(P),
    Files = etorrent_metainfo:get_files(Torrent),
    Name = etorrent_metainfo:get_name(Torrent),
    InfoHash = etorrent_metainfo:get_infohash(Torrent),
    FilesToCheck =
	[{filename:join([Workdir, Name, Filename]), Size} ||
	    {Filename, Size} <- Files],
    {ok, Torrent, FilesToCheck, InfoHash}.

ensure_file_sizes_correct(Files) ->
    lists:foreach(
      fun ({Pth, ISz}) ->
	      Sz = filelib:file_size(Pth),
	      if
		  (Sz /= ISz) ->
		      Missing = ISz - Sz,
		      fill_file_ensure_path(Pth, Missing);
		  true ->
		      ok
	      end
      end,
      Files),
    ok.

check_torrent_contents(FS, Id) ->
    {atomic, Pieces} = etorrent_piece:pieces(Id),
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
	      etorrent_piece:statechange(Id, PieceNum, State)
      end,
      Pieces),
    ok.

build_dictionary_on_files(Torrent, Files) ->
    Pieces = etorrent_metainfo:get_pieces(Torrent),
    PSize = etorrent_metainfo:get_piece_length(Torrent),
    LastPieceSize = torrent_size(Files) rem PSize,
    construct_fpmap(Files,
		    0,
		    PSize,
		    LastPieceSize,
		    lists:zip(lists:seq(0, length(Pieces)-1), Pieces),
		    [],
		    0).



%%====================================================================
%% Internal functions
%%====================================================================

add_filesystem(Id, SupervisorPid, FileDict) ->
    etorrent_piece:new(Id, FileDict),
    FSP = case etorrent_t_sup:add_file_system_pool(SupervisorPid) of
	      {ok, FSPool} ->
		  FSPool;
	      {error, {already_started, FSPool}} ->
		  FSPool
	  end,
    etorrent_t_sup:add_file_system(SupervisorPid, FSP, Id).

torrent_size(Files) ->
    lists:foldl(fun ({_F, S}, A) ->
			S + A
		end,
		0,
		Files).


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
    {ok, dict:from_list(Done), N};
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
    {ok, _NP} = file:position(FD, eof),
    ok = create_file(FD, Missing),
    file:close(FD).

create_file(FD, N) ->
    SZ4 = N div 4,
    Remaining = (N rem 4) * 8,
    create_file(FD, 0, SZ4),
    file:write(FD, <<0:Remaining/unsigned>>).

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
