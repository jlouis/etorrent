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
% <p>The torrent given by Id, and parsed content will be checked for
%  correctness. We return a tuple
%  with various information about said torrent: The decoded Torrent dictionary,
%  the info hash and the number of pieces in the torrent.</p>
% @end
-spec read_and_check_torrent(integer(), bcode()) -> {ok, integer()}.
read_and_check_torrent(Id, Torrent) ->
    {ok, Hashes} = initialize_dictionary(Id, Torrent),

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

    {ok, L}.

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

initialize_dictionary(Id, Torrent) ->
    ok = etorrent_io:allocate(Id),
    Hashes = etorrent_metainfo:get_pieces(Torrent),
    {ok, Hashes}.

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









