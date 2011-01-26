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
-export([read_and_check_torrent/2, check_torrent_for_bad_pieces/1, check_piece_completion/2]).

%% ====================================================================

% @doc Check the contents of torrent Id
% <p>We will check a torrent, Id, and report a list of bad pieces.</p>
% @end
-spec check_torrent_for_bad_pieces(integer()) -> [pos_integer()].
check_torrent_for_bad_pieces(Id) ->
    [PN || PN <- etorrent_piece_mgr:pieces(Id),
	   case check_piece(Id, PN) of
	       {ok, _} ->
		   false;
	       wrong_hash ->
		   true
	   end].

% @doc Read and check a torrent
% <p>The torrent given by Id, at Path (the .torrent file) will be checked for
%  correctness. We return a tuple
%  with various information about said torrent: The decoded Torrent dictionary,
%  the info hash and the number of pieces in the torrent.</p>
% @end
-spec read_and_check_torrent(integer(), string()) -> {ok, bcode(), binary(), integer()}.
read_and_check_torrent(Id, Path) ->
    {ok, Torrent, Infohash, Hashes} =
        initialize_dictionary(Path),

    L = length(Hashes),

    %% Check the contents of the torrent, updates the state of the piecemap
    FS = gproc:lookup_local_name({torrent, Id, fs}),
    case etorrent_fast_resume:query_state(Id) of
	{value, PL} ->
	    case proplists:get_value(state, PL) of
		seeding -> initialize_pieces_seed(Id, Hashes);
		{bitfield, BF} ->
		    initialize_pieces_from_bitfield(Id, BF, Hashes)
	    end;
        %% XXX: The next one here could initialize with not_fetched all over
        unknown ->
	    %% We currently have to pre-populate the piece data here, which is quite
	    %% bad. In the future:
	    %% @todo remove the prepopulation from the piece_mgr code.
            ok = etorrent_piece_mgr:add_pieces(
                   Id,
                  [{PN, Hash, dummy, not_fetched}
		   || {PN, Hash} <- lists:zip(lists:seq(0, L - 1),
					      Hashes)]),
            ok = initialize_pieces_from_disk(FS, Id, Hashes)
    end,

    {ok, Torrent, Infohash, L}.

%% @doc Check a piece for completion and mark it for correctness
%% @end
-spec check_piece_completion(torrent_id(), integer()) -> ok.
check_piece_completion(TorrentID, Idx) ->
    case check_piece(TorrentID, Idx) of
	{ok, PieceSize} ->
            ok = etorrent_torrent:statechange(TorrentID, [{subtract_left, PieceSize}]),
            ok = etorrent_piece_mgr:statechange(TorrentID, Idx, fetched),
            _  = etorrent_table:foreach_peer(TorrentID,
                     fun(Pid) -> etorrent_peer_control:have(Pid, Idx) end),
            ok;
        wrong_hash ->
            ok = etorrent_piece_mgr:statechange(TorrentID, Idx, not_fetched)
    end.

%% @doc Search the ETS tables for the Piece with Index and
%%      write it back to disk.
%% @end
-spec check_piece(torrent_id(), integer()) ->
			 {ok, integer()} | wrong_hash.
check_piece(TorrentID, PieceIndex) ->
    InfoHash = etorrent_piece_mgr:piece_hash(TorrentID, PieceIndex),
    {ok, PieceBin} = etorrent_io:read_piece(TorrentID, PieceIndex),
    case crypto:sha(PieceBin) == InfoHash of
	true ->
	    {ok, byte_size(PieceBin)};
	false ->
	    wrong_hash
    end.

%% =======================================================================

initialize_dictionary(Path) ->
    %% Load the torrent
    {ok, Torrent, Files, IH} = load_torrent(Path),
    ok = ensure_file_sizes_correct(Files),
    Hashes = etorrent_metainfo:get_pieces(Torrent),
    {ok, Torrent, IH, Hashes}.

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

initialize_pieces_seed(Id, Hashes) ->
    L = length(Hashes),
    etorrent_piece_mgr:add_pieces(
      Id,
      [{PN, Hash, dummy, fetched}
       || {PN, Hash} <- lists:zip(lists:seq(0,L - 1),
				  Hashes)]).

initialize_pieces_from_bitfield(Id, BitField, Hashes) ->
    L = length(Hashes),
    {ok, Set} = etorrent_proto_wire:decode_bitfield(L, BitField),
    F = fun (PN) ->
                case gb_sets:is_element(PN, Set) of
                    true -> fetched;
                    false -> not_fetched
                end
        end,
    Pieces = [{PN, Hash, dummy, F(PN)}
	      || {PN, Hash} <- lists:zip(lists:seq(0, L - 1),
					 Hashes)],
    etorrent_piece_mgr:add_pieces(Id, Pieces).

initialize_pieces_from_disk(_, Id, Hashes) ->
    L = length(Hashes),
    F = fun(PN, Hash) ->
		State = case check_piece(Id, PN) of
			    {ok, _} -> fetched;
			    wrong_hash -> not_fetched
			end,
		{PN, Hash, dummy, State}
        end,
    etorrent_piece_mgr:add_pieces(
      Id,
      [F(PN, Hash)
       || {PN, Hash} <- lists:zip(lists:seq(0, L - 1),
				  Hashes)]).

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
