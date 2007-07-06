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
    FilesToCheck = lists:map(fun (E) ->
				     {Filename, Size} = report_files(E),
				     io:format("Found ~s at length ~B~n", [Filename, Size]),
				     {string:concat(string:concat(Name, "/"), Filename), Size}
			     end,
			     Files),
    size_check_files(FilesToCheck),
    build_dictionary_on_files(Torrent, FilesToCheck).

size_check_files(Entries) ->
    lists:map(fun ({Pth, ISz}) ->
		      case (filelib:file_size(Pth) == ISz) of
			  true ->
			      io:format("Path ~s is ok~n", [Pth])
		      end
	      end,
	      Entries),
    ok.

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
	    {ok, [{Pth, Sz} | R], Offset+Left, [{Pth, Offset, Left} | Building]};
	false ->
	    % There is not enough space left in Pth
	    BytesWeCanGet = Sz - Offset,
	    extract_piece(Left - BytesWeCanGet, R, 0, [{Pth, Offset, BytesWeCanGet} | Building])
    end.

construct_fpmap([], _Offset, _PieceSize, _LPS, [], Done) ->
    {ok, dict:from_list(Done)};
construct_fpmap([], _O, _P, _LPS, _Pieces, _D) ->
    error_more_pieces;
construct_fpmap(FileList, Offset, PieceSize, LastPieceSize, [{Num, Hash}], Done) -> % Last piece
    {ok, FL, OS, Ops} = extract_piece(LastPieceSize, FileList, Offset, []),
    construct_fpmap(FL, OS, PieceSize, LastPieceSize, [], [{Num, {Hash, Ops}} | Done]);
construct_fpmap(FileList, Offset, PieceSize, LastPieceSize, [{Num, Hash} | Ps], Done) ->
    {ok, FL, OS, Ops} = extract_piece(PieceSize, FileList, Offset, []),
    construct_fpmap(FL, OS, PieceSize, LastPieceSize, Ps, [{Num, {Hash, Ops}} | Done]).
