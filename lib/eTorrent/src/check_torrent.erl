%%%-------------------------------------------------------------------
%%% File    : check_torrent.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus.local.domain>
%%% Description : Code for checking the correctness of a torrent file map
%%%
%%% Created :  6 Jul 2007 by Jesper Louis Andersen <jlouis@succubus.local.domain>
%%%-------------------------------------------------------------------
-module(check_torrent).

%% API
-export([check_torrent/1]).

%%====================================================================
%% API
%%====================================================================
check_torrent(Path) ->
    {ok, Torrent} = metainfo:parse(Path),

    {list, Files} = metainfo:get_files(Torrent),
    Name = metainfo:get_name(Torrent),
    FilesToCheck =
	lists:map(fun (E) ->
			  {Filename, Size} = report_files(E),
			  io:format("Found ~s at length ~B~n",
				    [Filename, Size]),
			  {string:concat(string:concat(Name, "/"), Filename),
			   Size}
		  end,
		  Files),
    size_check_files(FilesToCheck),
    {ok, FileDict} =
	build_dictionary_on_files(Torrent, FilesToCheck),
    {ok, Res} = check_torrent_contents(FileDict),
    Res.

check_torrent_contents(FileDict) ->
    {ok, FileChecker} = file_system:start_link(FileDict),
    Res = dict:map(fun (PN, {Hash, Ops, none}) ->
 		      {ok, Data} = file_system:read_piece(FileChecker, PN),
		      case Hash == crypto:sha(Data) of
			  true ->
			      {Hash, Ops, ok};
			  false ->
			      {Hash, Ops, not_ok}
		      end
 	      end,
 	      FileDict),
    file_system:stop(FileChecker),
    {ok, Res}.

size_check_files(Entries) ->
    lists:map(fun ({Pth, ISz}) ->
		      Sz = filelib:file_size(Pth),
		      case (Sz == ISz) of
			  true ->
			      io:format("Path ~s is ok~n", [Pth]);
			  false ->
			      io:format("Path ~s is to small, filling", [Pth]),
			      Missing = ISz - Sz,
			      fill_file_ensure_path(Pth, Missing)
		      end
	      end,
	      Entries),
    ok.

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
    ok = create_file_slow(FD, Missing),
    file:close(FD).

create_file(FD, N) ->
    create_file(FD, 0, N).

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
                [<<N8:8/unsigned,  N7:8/unsigned,
		   N6:8/unsigned,  N5:8/unsigned,
		   N4:8/unsigned,  N3:8/unsigned,
                   N2:8/unsigned,  N1:8/unsigned>> | R]);
create_file(FD, M, N0, R) ->
    N1 = N0-1,
    create_file(FD, M, N1, [<<N1:8/unsigned>> | R]).


create_file_slow(FD, N) when integer(N), N >= 0 ->
    ok = create_file_slow(FD, 0, N),
    ok.

create_file_slow(_FD, M, M) ->
    ok;
create_file_slow(FD, M, N) ->
    ok = file:write(FD, <<M:8/unsigned>>),
    create_file_slow(FD, M+1, N).

%%====================================================================
%% Internal functions
%%====================================================================
report_files(Entry) ->
    {dict,[{{string,"path"},
	    {list,[{string,Filename}]}},
	   {{string,"length"},{integer,Size}}]} = Entry,
    {Filename, Size}.

torrent_size(Files) ->
    lists:foldl(fun ({_F, S}, A) ->
			S + A
		end,
		0,
		Files).

build_dictionary_on_files(Torrent, Files) ->
    Pieces = metainfo:get_pieces(Torrent),
    PSize = metainfo:get_piece_length(Torrent),
    LastPieceSize = torrent_size(Files) rem PSize,
    construct_fpmap(Files,
		    0,
		    PSize,
		    LastPieceSize,
		    lists:zip(lists:seq(1, length(Pieces)), Pieces),
		    []).

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

construct_fpmap([], _Offset, _PieceSize, _LPS, [], Done) ->
    {ok, dict:from_list(Done)};
construct_fpmap([], _O, _P, _LPS, _Pieces, _D) ->
    error_more_pieces;
construct_fpmap(FileList, Offset, PieceSize, LastPieceSize,
		[{Num, Hash}], Done) -> % Last piece
    {ok, FL, OS, Ops} = extract_piece(LastPieceSize, FileList, Offset, []),
    construct_fpmap(FL, OS, PieceSize, LastPieceSize, [],
		    [{Num, {Hash, lists:reverse(Ops), none}} | Done]);
construct_fpmap(FileList, Offset, PieceSize, LastPieceSize,
		[{Num, Hash} | Ps], Done) ->
    {ok, FL, OS, Ops} = extract_piece(PieceSize, FileList, Offset, []),
    construct_fpmap(FL, OS, PieceSize, LastPieceSize, Ps,
		    [{Num, {Hash, lists:reverse(Ops), none}} | Done]).
