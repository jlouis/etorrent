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
-export([new_torrent/2, find_torrents_by_file/1, cleanup_torrent_by_pid/1,
	 store_info_hash/2, set_info_hash_state/2, select_info_hash/2,
	 select_info_hash/1, delete_info_hash/1, delete_info_hash_by_pid/1,
	 store_peer/4, select_peer_ip_port_by_pid/1, delete_peer/1,
	 peer_statechange/2, is_peer_connected/3, select_interested_peers/1,
	 reset_round/1, delete_peers/1, peer_statechange_infohash/2]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: new_torrent(Filename, Supervisor) -> ok
%% Description: Add a new torrent given by File with the Supervisor
%%   pid as given to the database structure.
%%--------------------------------------------------------------------
new_torrent(File, Supervisor) ->
    T = fun () ->
		mnesia:write(#tracking_map { filename = File,
					     supervisor_pid = Supervisor })
	end,
    mnesia:transaction(T).

%%--------------------------------------------------------------------
%% Function: find_torrents_by_file(Filename) -> [SupervisorPid]
%% Description: Find torrent specs matching the filename in question.
%%--------------------------------------------------------------------
find_torrents_by_file(Filename) ->
    Query = qlc:q([T#tracking_map.filename || T <- mnesia:table(tracking_map),
					      T#tracking_map.filename == Filename]),
    qlc:e(Query).

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
%% Function: store_info_hash(InfoHash, StorerPid, MonitorRef) -> transaction
%% Description: Store that InfoHash is controlled by StorerPid with assigned
%%  monitor reference MonitorRef
%%--------------------------------------------------------------------
store_info_hash(InfoHash, StorerPid) ->
    F = fun() ->
		mnesia:write(#info_hash { info_hash = InfoHash,
					  storer_pid = StorerPid,
					  state = unknown })
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function: set_info_hash_state(InfoHash, State) -> ok | not_found
%% Description: Set the state of an info hash.
%%--------------------------------------------------------------------
set_info_hash_state(InfoHash, State) ->
    F = fun() ->
		case mnesia:read(info_hash, InfoHash, write) of
		    [IH] ->
			New = IH#info_hash{state = State},
			mnesia:write(New),
			ok;
		    [] ->
			not_found
		end
	end,
    {atomic, Res} = mnesia:transaction(F),
    Res.

%%--------------------------------------------------------------------
%% Function: select_info_hash_pids(InfoHash, Pid) -> Rows
%% Description: Return rows matching infohash and pid
%%--------------------------------------------------------------------
select_info_hash(InfoHash, Pid) ->
    Q = qlc:q([IH || IH <- mnesia:table(info_hash),
		     IH#info_hash.info_hash =:= InfoHash,
		     IH#info_hash.storer_pid =:= Pid]),
    qlc:e(Q).

%%--------------------------------------------------------------------
%% Function: select_info_hash_pids(InfoHash) -> Pids
%% Description: Return all rows matching infohash
%%--------------------------------------------------------------------
select_info_hash(InfoHash) ->
    Q = qlc:q([IH || IH <- mnesia:table(info_hash),
		     IH#info_hash.info_hash =:= InfoHash]),
    qlc:e(Q).

%%--------------------------------------------------------------------
%% Function: delete_info_hash(InfoHash) -> transaction
%% Description: Remove the row with InfoHash in it
%%--------------------------------------------------------------------
delete_info_hash(InfoHash) ->
    F = fun() ->
		mnesia:delete(info_hash, InfoHash, write)
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function: delete_info_hash_by_pid(Pid) -> transaction
%% Description: Remove the row with Pid in it
%%--------------------------------------------------------------------
delete_info_hash_by_pid(Pid) ->
    F = fun() ->
		Q = qlc:q([IH#info_hash.info_hash || IH <- mnesia:table(info_hash),
						     IH#info_hash.storer_pid =:= Pid]),
		lists:foreach(fun (H) ->
				      mnesia:delete(info_hash, H, write)
			      end,
			      qlc:e(Q))
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
	      P = mnesia:read(peer_map, Pid, write),
	      mnesia:delete(info_hash, P#peer_map.info_hash, write),
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
		Ref = mnesia:read(peer, Pid, read), %% Read lock here?
		PI = mnesia:read(peer_info, Ref, write),
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
		mnesia:write(peer_info, New, write)
	end,
    mnesia:transaction(F).


is_peer_connected(IP, Port, InfoHash) ->
    Q = qlc:q([PM#peer_map.pid || PM <- mnesia:table(peer_map),
				  PM#peer_map.ip =:= IP,
				  PM#peer_map.port =:= Port,
				  PM#peer_map.info_hash =:= InfoHash]),
    case qlc:e(Q) of
	[] ->
	    false;
	_ ->
	    true
    end.

select_interested_peers(InfoHash) ->
    InterestedQuery = build_interest_query(true, InfoHash),
    NotInterestedQuery = build_interest_query(false, InfoHash),
    {qlc:e(InterestedQuery), qlc:e(NotInterestedQuery)}.

reset_round(InfoHash) ->
    F = fun() ->
		Q1 = qlc:q([P || PM <- mnesia:table(peer_map),
				 P  <- mnesia:table(peers),
				 PM#peer_map.info_hash =:= InfoHash,
				 P#peer.map =:= PM#peer_map.pid]),
		Q2 = qlc:q([PI || P <- Q1,
				  PI <- mnesia:table(peer_info),
				  PI#peer_info.id =:= P#peer.info]),
		Peers = qlc:e(Q2),
		lists:foreach(fun (P) ->
				      New = P#peer_info{uploaded = 0, downloaded = 0},
				      mnesia:write(peer_info, New, write) end,
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


