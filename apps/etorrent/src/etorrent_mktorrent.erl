%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Create .torrent files
%% Use the rpc module to make the creation parallel.
%% @end
-module(etorrent_mktorrent).

-include_lib("kernel/include/file.hrl").
-include("log.hrl").

%% API
-export([create/3, create/4]).

-define(CHUNKSIZE, 1048576).
%%====================================================================

%% @equiv create(FD, AnnounceURL, OutFile, null)
create(FD, AnnounceURL, OutFile) ->
    create(FD, AnnounceURL, OutFile, null).

%% @doc Create a torrent file.
%% Given a File or directory `FD' a desired `AnnounceURL' and a output
%% file name `OutFile' for a .torrent, construct it the contents of
%% a torrent file. Finally, an Optional comment can be included.
%% @end
create(FD, AnnounceURL, OutFile, Comment) ->
    {PieceHashes, FileInfo} = read_and_hash(FD),
    TorrentData = torrent_file(AnnounceURL, PieceHashes, FileInfo, Comment),
    write_torrent_file(OutFile, TorrentData).

hash_file(File, {PH, InfoBlocks}) ->
    {ok, FI} = file:read_file_info(File),
    IB = {File, FI},
    {ok, IODev} = file:open(File, [read, binary, read_ahead]),
    PHUpdate = add_hashes(IODev, PH),
    {PHUpdate, [IB | InfoBlocks]}.

add_hashes(IODev, PH) ->
    hash(IODev, file:read(IODev, ?CHUNKSIZE), PH).

cut_chunk({Bin, Hashes}) when byte_size(Bin) >= ?CHUNKSIZE ->
    <<Chunk:?CHUNKSIZE/binary, Rest/binary>> = Bin,
    cut_chunk({Rest, [rpc:async_call(node(), crypto, sha, [Chunk]) | Hashes]});
cut_chunk(Otherwise) -> Otherwise.

hash(IODev, eof, PH) ->
    file:close(IODev),
    cut_chunk(PH);
hash(IODev, {ok, NewData}, {Bin, Hashes}) ->
    hash(IODev, file:read(IODev, ?CHUNKSIZE),
	 cut_chunk({<<Bin/binary, NewData/binary>>, Hashes})).

read_and_hash(Arg) ->
    Empty = {{<<>>, []}, []},
    PH = case filelib:is_dir(Arg) of
	true -> filelib:fold_files(Arg, ".*", true, fun hash_file/2, Empty);
	false ->
	    true = filelib:is_regular(Arg),
	    hash_file(Arg, Empty)
    end,
    {Keys, FIs} = finish_hash(PH),
    {iolist_to_binary([rpc:yield(K) || K <- Keys]), FIs}.

finish_hash({{<<>>, Hashes}, FI}) -> {lists:reverse(Hashes),
				      lists:reverse(FI)};
finish_hash({{Bin, Hashes}, FI}) ->
    K = rpc:async_call(node(), crypto, sha, [Bin]),
    {lists:reverse([K | Hashes]),
     lists:reverse(FI)}.

-spec mk_comment(null | list()) -> [term()].
mk_comment(null) -> [];
mk_comment(Comment) when is_list(Comment) ->
    [{<<"comment">>, list_to_binary(Comment)}].

mk_infodict_single(PieceHashes, Name, Sz) when is_binary(PieceHashes) ->
    [{<<"pieces">>, PieceHashes},
     {<<"piece length">>, ?CHUNKSIZE},
     {<<"name">>,   list_to_binary(Name)},
     {<<"length">>, Sz}].

mk_files_list([], Accum, Sz) ->
    {Sz, lists:reverse(Accum)};
mk_files_list([{N, #file_info { size = Size }} | R], Acc, S) ->
    D = [{<<"path">>, list_to_binary(N)},
	 {<<"size">>, Size}],
    mk_files_list(R, [D | Acc], S + Size).

mk_infodict_multi(PieceHashes, D) when is_binary(PieceHashes) ->
    {Sz, L} = mk_files_list(D, [], 0),
    [{<<"pieces">>, PieceHashes},
     {<<"length">>, Sz},
     {<<"piece length">>, ?CHUNKSIZE},
     {<<"files">>, L}].

write_torrent_file(Out, Data) ->
    Encoded = etorrent_bcoding:encode(Data),
    file:write_file(Out, Encoded).

torrent_file(AnnounceURL, PieceHashes, FileInfo, Comment) ->
    InfoDict = case FileInfo of
		   [{Name, #file_info { size = Sz }}] ->
		       mk_infodict_single(PieceHashes, Name, Sz);
		   L when is_list(L) ->
		       mk_infodict_multi(PieceHashes, L)
	       end,
    [{<<"announce">>, list_to_binary(AnnounceURL)},
     {<<"info">>, InfoDict}] ++ mk_comment(Comment).















