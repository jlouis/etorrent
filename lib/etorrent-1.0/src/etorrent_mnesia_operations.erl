%%%-------------------------------------------------------------------
%%% File    : etorrent_mnesia_operations.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Various mnesia operations
%%%
%%% Created : 25 Mar 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_mnesia_operations).

-include_lib("stdlib/include/qlc.hrl").

-include("etorrent_mnesia_table.hrl").


%% API
%%% TODO: Consider splitting this code into more parts. Easily done per table.
-export([cleanup_torrent_by_pid/1,
	 store_torrent/2, set_torrent_state/2,
	 select_torrent/1, delete_torrent/1, delete_torrent_by_pid/1,
	 store_peer/4, select_peer_ip_port_by_pid/1, delete_peer/1,
	 peer_statechange/2, is_peer_connected/3, select_interested_peers/1,
	 reset_round/1, delete_peers/1, peer_statechange_infohash/2,

	 %% Manipulating the tracking map
	 tracking_map_new/3,
	 tracking_map_by_infohash/1, tracking_map_by_file/1,

	 %% Manipulating pieces
	 pieces_torrent_size/1,
	 pieces_check_interest/2,
	 pieces_get_num/1,
	 pieces_get_bitfield/1,

	 %% This is incorrently named as file_access. Should be pieces.
	 file_access_new/2, file_access_set_state/3,
	 file_access_torrent_pieces/1, file_access_is_complete/1,
	 file_access_get_pieces/1, file_access_delete/1,
	 file_access_get_piece/2,
	 file_access_piece_valid/2,
	 file_access_piece_interesting/2]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: tracking_map_new(Filename, Supervisor) -> ok
%% Description: Add a new torrent given by File with the Supervisor
%%   pid as given to the database structure.
%%--------------------------------------------------------------------
tracking_map_new(File, Supervisor, Id) ->
    mnesia:dirty_write(#tracking_map { id = Id,
				       filename = File,
				       supervisor_pid = Supervisor }).

%%--------------------------------------------------------------------
%% Function: tracking_map_by_file(Filename) -> [SupervisorPid]
%% Description: Find torrent specs matching the filename in question.
%%--------------------------------------------------------------------
tracking_map_by_file(Filename) ->
    mnesia:transaction(
      fun () ->
	      Query = qlc:q([T#tracking_map.filename || T <- mnesia:table(tracking_map),
							T#tracking_map.filename == Filename]),
	      qlc:e(Query)
      end).

%%--------------------------------------------------------------------
%% Function: tracking_map_by_infohash(Infohash) -> [#tracking_map]
%% Description: Find tracking map matching a given infohash.
%%--------------------------------------------------------------------
tracking_map_by_infohash(InfoHash) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([T || T <- mnesia:table(tracking_map),
			      T#tracking_map.info_hash =:= InfoHash]),
	      qlc:e(Q)
      end).


%%--------------------------------------------------------------------
%% Function: pieces_check_interest(Handle, PieceSet) ->
%% Description: Returns the interest of a peer
%%--------------------------------------------------------------------
pieces_check_interest(Id, PieceSet) when is_integer(Id) ->
    %%% XXX: This function could also check for validity and probably should
    F = fun () ->
		Q = qlc:q([R#file_access.piece_number ||
			      R <- mnesia:table(file_access),
			      R#file_access.id =:= Id,
			      (R#file_access.state =:= fetched)
				  orelse (R#file_access.state =:= chunked)]),
		qlc:e(Q)
	end,
    {atomic, PS} = mnesia:transaction(F),
    case sets:size(sets:intersection(sets:from_list(PS), PieceSet)) of
	0 ->
	    not_interested;
	N when is_integer(N) ->
	    interested
    end.


%%--------------------------------------------------------------------
%% Function: pieces_get_num(Pid) -> integer()
%% Description: Return the number of pieces for the given torrent
%%--------------------------------------------------------------------
pieces_get_num(Id) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q1 = qlc:q([Q || Q <- mnesia:table(file_access),
			       Q#file_access.id =:= Id]),
	      length(qlc:e(Q1))
      end).

%%--------------------------------------------------------------------
%% Function: pieces_get_bitfield(Pid) -> bitfield()
%% Description: Return the bitfield we have for the given torrent
%%--------------------------------------------------------------------
pieces_get_bitfield(Id) when is_integer(Id) ->
    {atomic, NumPieces} = pieces_get_num(Id), %%% May be stored once and for all rather than calculated
    {atomic, Fetched}   = pieces_get_fetched(Id),
    etorrent_peer_communication:construct_bitfield(NumPieces,
						   sets:from_list(Fetched)).

pieces_get_fetched(Id) when is_integer(Id) ->
    F = fun () ->
		Q = qlc:q([R#file_access.piece_number ||
			      R <- mnesia:table(file_access),
			      R#file_access.id =:= Id,
			      R#file_access.state =:= fetched]),
		qlc:e(Q)
	end,
    mnesia:transaction(F).


%%--------------------------------------------------------------------
%% Function: pieces_torrent_size(Pid) -> integer()
%% Description: What is the total size of the torrent in question.
%%--------------------------------------------------------------------
pieces_torrent_size(Id) when is_integer(Id) ->
    F = fun () ->
		Query = qlc:q([F || F <- mnesia:table(file_access),
				    F#file_access.id =:= Id]),
		qlc:e(Query)
	end,
    {atomic, Res} = mnesia:transaction(F),
    lists:foldl(fun(#file_access{ files = {_, Ops, _}}, Sum) ->
			Sum + etorrent_fs:size_of_ops(Ops)
		end,
		0,
		Res).


%%--------------------------------------------------------------------
%% Function: cleanup_torrent_by_pid(Pid) -> ok
%% Description: Clean out all references to torrents matching Pid
%%--------------------------------------------------------------------
cleanup_torrent_by_pid(Pid) ->
    F = fun() ->
		Query = qlc:q([T#tracking_map.filename || T <- mnesia:table(tracking_map),
							  T#tracking_map.supervisor_pid =:= Pid]),
		lists:foreach(fun (F) -> mnesia:delete(tracking_map, F, write) end, qlc:e(Query))
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function: store_torrent(InfoHash, StorerPid, MonitorRef) -> transaction
%% Description: Store that InfoHash is controlled by StorerPid with assigned
%%  monitor reference MonitorRef
%%--------------------------------------------------------------------
store_torrent(Id, {{uploaded, U}, {downloaded, D}, {left, L}}) ->
    F = fun() ->
		mnesia:write(#torrent { id = Id,
					left = L,
					uploaded = U,
					downloaded = D,
					state = unknown })
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function: set_torrent_state(InfoHash, State) -> ok | not_found
%% Description: Set the state of an info hash.
%%--------------------------------------------------------------------
set_torrent_state(Id, S) when is_integer(Id) ->
    F = fun() ->
		case mnesia:read(torrent, Id, write) of
		    [T] ->
			New = case S of
				  unknown ->
				      T#torrent{state = unknown};
				  leeching ->
				      T#torrent{state = leeching};
				  seeding ->
				      T#torrent{state = seeding};
				  endgame ->
				      T#torrent{state = endgame};
				  {add_downloaded, Amount} ->
				      T#torrent{downloaded = T#torrent.downloaded + Amount};
				  {add_upload, Amount} ->
				      T#torrent{uploaded = T#torrent.uploaded + Amount};
				  {substract_left, Amount} ->
				      T#torrent{left = T#torrent.left - Amount};
				  {tracker_report, Seeders, Leechers} ->
				      T#torrent{seeders = Seeders, leechers = Leechers}
			      end,
			mnesia:write(New),
			ok;
		    [] ->
			not_found
		end
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function: select_torrent(Id, Pid) -> Rows
%% Description: Return the torrent identified by Id
%%--------------------------------------------------------------------
select_torrent(Id) ->
    mnesia:dirty_read(torrent, Id).

%%--------------------------------------------------------------------
%% Function: delete_torrent(InfoHash) -> transaction
%% Description: Remove the row with InfoHash in it
%%--------------------------------------------------------------------
delete_torrent(InfoHash) when is_binary(InfoHash) ->
    mnesia:transaction(
      fun () ->
	      case mnesia:read(torrent, infohash, write) of
		  [R] ->
		      {atomic, _} = delete_torrent(R);
		  [] ->
		      ok
	      end
      end);
delete_torrent(Torrent) when is_record(Torrent, torrent) ->
    F = fun() ->
		mnesia:delete_object(Torrent)
	end,
    mnesia:transaction(F).


%%--------------------------------------------------------------------
%% Function: delete_torrent_by_pid(Pid) -> transaction
%% Description: Remove the row with Pid in it
%%--------------------------------------------------------------------
delete_torrent_by_pid(Id) ->
    error_logger:info_report([delete_torrent_by_pid, Id]),
    F = fun () ->
		Tr = mnesia:read(torrent, Id),
		mnesia:delete(Tr)
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function: store_peer(IP, Port, InfoHash, Pid) -> transaction
%% Description: Store a row for the peer
%%--------------------------------------------------------------------
store_peer(IP, Port, InfoHash, Pid) ->
    F = fun() ->
		{atomic, Ref} = create_peer_info(),
		mnesia:write(#peer_map { pid = Pid,
					 ip = IP,
					 port = Port,
					 info_hash = InfoHash}),

		mnesia:write(#peer { map = Pid,
				     info = Ref })
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function: select_peer_ip_port_by_pid(Pid) -> rows
%% Description: Select the IP and Port pair of a Pid
%%--------------------------------------------------------------------
select_peer_ip_port_by_pid(Pid) ->
    Q = qlc:q([{PM#peer_map.ip,
		PM#peer_map.port} || PM <- mnesia:table(peer_map),
				     PM#peer_map.pid =:= Pid]),
    qlc:e(Q).

%%--------------------------------------------------------------------
%% Function: delete_peer(Pid) -> transaction
%% Description: Delete all references to the peer owned by Pid
%%--------------------------------------------------------------------
delete_peer(Pid) ->
    mnesia:transaction(
      fun () ->
	      [P] = mnesia:read(peer_map, Pid, write),
	      mnesia:delete(torrent, P#peer_map.info_hash, write),
	      mnesia:delete(peer_map, Pid, write)
      end).

peer_statechange_infohash(InfoHash, What) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([P#peer_map.pid || P <- mnesia:table(peer_map),
					   P#peer_map.info_hash =:= InfoHash]),
	      Pids = qlc:e(Q),
	      lists:foreach(fun (Pid) ->
				    peer_statechange(Pid, What)
			    end,
			    Pids)
      end).

peer_statechange(Pid, What) ->
    F = fun () ->
		[Peer] = mnesia:read(peer, Pid, read), %% Read lock here?
		[PI] = mnesia:read(peer_info, Peer#peer.info, write),
		case What of
		    {optimistic_unchoke, Val} ->
			New = PI#peer_info{ optimistic_unchoke = Val };
		    remove_optimistic_unchoke ->
			New = PI#peer_info{ optimistic_unchoke = false };
		    remote_choking ->
			New = PI#peer_info{ remote_choking = true};
		    remote_unchoking ->
			New = PI#peer_info{ remote_choking = false};
		    interested ->
			New = PI#peer_info{ interested = true};
		    not_intersted ->
			New = PI#peer_info{ interested = false};
		    {uploaded, Amount} ->
			Uploaded = PI#peer_info.uploaded,
			New = PI#peer_info{ uploaded = Uploaded + Amount };
		    {downloaded, Amount} ->
			Downloaded = PI#peer_info.downloaded,
			New = PI#peer_info{ downloaded = Downloaded + Amount }
		end,
		mnesia:write(New),
		ok
	end,
    mnesia:transaction(F).


is_peer_connected(IP, Port, InfoHash) ->
    Query =
	fun () ->
		Q = qlc:q([PM#peer_map.pid || PM <- mnesia:table(peer_map),
					      PM#peer_map.ip =:= IP,
					      PM#peer_map.port =:= Port,
					      PM#peer_map.info_hash =:= InfoHash]),
		case qlc:e(Q) of
		    [] ->
			false;
		    _ ->
			true
		end
	end,
    mnesia:transaction(Query).

select_interested_peers(InfoHash) ->
    mnesia:transaction(
      fun () ->
	      InterestedQuery = build_interest_query(true, InfoHash),
	      NotInterestedQuery = build_interest_query(false, InfoHash),
	      {qlc:e(InterestedQuery), qlc:e(NotInterestedQuery)}
      end).


reset_round(InfoHash) ->
    F = fun() ->
		Q1 = qlc:q([P || PM <- mnesia:table(peer_map),
				 P  <- mnesia:table(peer),
				 PM#peer_map.info_hash =:= InfoHash,
				 P#peer.map =:= PM#peer_map.pid]),
		Q2 = qlc:q([PI || P <- Q1,
				  PI <- mnesia:table(peer_info),
				  PI#peer_info.id =:= P#peer.info]),
		Peers = qlc:e(Q2),
		lists:foreach(fun (P) ->
				      New = P#peer_info{uploaded = 0, downloaded = 0},
				      mnesia:write(New) end,
			      Peers)
	end,
    mnesia:transaction(F).

delete_peers(Pid) ->
    mnesia:transaction(fun () ->
      delete_peer_info_hash(Pid),
      delete_peer_map(Pid)
       end).


delete_peer_map(Pid) ->
   mnesia:transaction(fun () ->
     mnesia:delete(peer_map, Pid, write) end).

delete_peer_info_hash(Pid) ->
  mnesia:transaction(fun () ->
    Q = qlc:q([PI#peer_info.id || P <- mnesia:table(peer),
				  P#peer.map =:= Pid,
				  PI <- mnesia:table(peer_info),
				  PI#peer_info.id =:= P#peer.info]),
    Refs = qlc:e(Q),
    lists:foreach(fun (R) -> mnesia:delete(peer_info, R, write) end,
                  Refs)
    end).


file_access_delete(Pid) ->
    mnesia:transaction(
      fun () ->
	      mnesia:delete(file_access, Pid, write)
      end).

file_access_new(Id, Dict) when is_integer(Id) ->
    dict:map(fun (PN, {Hash, Files, Done}) ->
		     State = case Done of
				 ok -> fetched;
				 not_ok -> not_fetched;
				 none -> not_fetched
			     end,
		     mnesia:dirty_write(
		       #file_access {id = Id,
				     piece_number = PN,
				     hash = Hash,
				     files = Files,
				     state = State })
		       end,
		       Dict).

file_access_set_state(Id, Pn, State) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([R || R <- mnesia:table(file_access),
			      R#file_access.id =:= Id,
			      R#file_access.piece_number =:= Pn]),
	      [Row] = qlc:e(Q),
	      mnesia:write(Row#file_access{state = State})
      end).

file_access_torrent_pieces(Id) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([{R#file_access.piece_number,
			  R#file_access.files,
			  R#file_access.state} || R <- mnesia:table(file_access),
						  R#file_access.id =:= Id]),
	      qlc:e(Q)
      end).

file_access_is_complete(Id) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([R || R <- mnesia:table(file_access),
			      R#file_access.id =:= Id,
			      R#file_access.state =:= not_fetched]),
	      Objs = qlc:e(Q),
	      length(Objs) =:= 0
      end).

file_access_get_pieces(Id) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([R || R <- mnesia:table(file_access),
			      R#file_access.id =:= Id]),
	      qlc:e(Q)
      end).

file_access_get_piece(Id, Pn) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([R || R <- mnesia:table(file_access),
			      R#file_access.id =:= Id,
			      R#file_access.piece_number =:= Pn]),
	      qlc:e(Q)
      end).

file_access_piece_valid(Id, Pn) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([R || R <- mnesia:table(file_access),
			      R#file_access.id =:= Id,
			      R#file_access.piece_number =:= Pn]),
	      case qlc:e(Q) of
		  [] ->
		      false;
		  [_] ->
		      true
	      end
      end).

file_access_piece_interesting(Id, Pn) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([R || R <- mnesia:table(file_access),
			      R#file_access.id =:= Id,
			      R#file_access.piece_number =:= Pn]),
	      [R] = qlc:e(Q),
	      case R#file_access.state of
		  fetched ->
		      false;
		  chunked ->
		      true;
		  not_fetched ->
		      true
	      end
      end).

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

build_interest_query(Interest, InfoHash) ->
    Q = qlc:q([P || PM <- mnesia:table(peer_map),
		    P <- mnesia:table(peer),
		    P#peer.map =:= PM#peer_map.pid,
		    PM#peer_map.info_hash =:= InfoHash]),
    qlc:q([{P#peer.map,
	    PI#peer_info.uploaded,
	    PI#peer_info.downloaded}
	   || P <- Q,
	      PI <- mnesia:table(peer_info),
	      PI#peer_info.id =:= P#peer.info,
	      PI#peer_info.interested =:= Interest]).

create_peer_info() ->
    F = fun() ->
		Ref = make_ref(),
		mnesia:write(#peer_info { id = Ref,
					  uploaded = 0,
					  downloaded = 0,
					  interested = false,
					  remote_choking = true,
					  optimistic_unchoke = false}),
		Ref
	end,
    mnesia:transaction(F).
