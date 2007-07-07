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
    check_torrent_contents(FileDict).

check_torrent_contents(FileDict) ->
    {ok, FileChecker} = file_system:start_link(FileDict),
    Res = dict:map(fun (PN, {Hash, Ops}) ->
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
			      fill_bytes_to_file(Pth, Missing)
		      end
	      end,
	      Entries),
    ok.

fill_bytes_to_file(Path, Missing) ->
    {ok, FD} = file:open(Path, [read, write, delayed_write, binary, raw]),
    {ok, _NP} = file:position(FD, eof),
    ok = create_file_slow(FD, Missing),
    ok = file:close(FD),
    ok.

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
		    [{Num, {Hash, lists:reverse(Ops)}} | Done]);
construct_fpmap(FileList, Offset, PieceSize, LastPieceSize,
		[{Num, Hash} | Ps], Done) ->
    {ok, FL, OS, Ops} = extract_piece(PieceSize, FileList, Offset, []),
    construct_fpmap(FL, OS, PieceSize, LastPieceSize, Ps,
		    [{Num, {Hash, lists:reverse(Ops)}} | Done]).
