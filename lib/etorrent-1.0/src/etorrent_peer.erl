%%%-------------------------------------------------------------------
%%% File    : etorrent_peer.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Manipulations of the peer mnesia table.
%%%
%%% Created : 16 Jun 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_peer).

-include_lib("stdlib/include/qlc.hrl").
-include("etorrent_mnesia_table.hrl").

%% API
-export([new/4, delete/1, statechange/2, is_connected/3, reset_round/1,
	 get_ip_port/1, partition_peers_by_interest/1]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: 
%% Description:
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: new(IP, Port, InfoHash, Pid) -> transaction
%% Description: Insert a row for the peer
%%--------------------------------------------------------------------
new(IP, Port, TorrentId, Pid) ->
    mnesia:dirty_write(#peer { pid = Pid,
			       ip = IP,
			       port = Port,
			       torrent_id = TorrentId}).

%%--------------------------------------------------------------------
%% Function: get_ip_port(Pid) -> {IP, Port}
%% Description: Select the IP and Port pair of a Pid
%%--------------------------------------------------------------------
get_ip_port(Pid) ->
    [R] = mnesia:dirty_read(peer, Pid),
    {R#peer.ip, R#peer.port}.

%%--------------------------------------------------------------------
%% Function: delete(Pid) -> ok | {aborted, Reason}
%% Description: Delete all references to the peer owned by Pid
%%--------------------------------------------------------------------
delete(Pid) ->
    mnesia:dirty_delete(peer, Pid).

%%--------------------------------------------------------------------
%% Function: statechange(Id, What) -> transaction
%% Description: Alter all peers matching torrent Id by What
%%--------------------------------------------------------------------
statechange(Id, What) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      Q = qlc:q([P || P <- mnesia:table(peer),
			      P#peer.torrent_id =:= Id]),
	      lists:foreach(fun (R) ->
				    NR = alter_state(R, What),
				    mnesia:write(NR)
			    end,
			    qlc:e(Q))
      end);

%%--------------------------------------------------------------------
%% Function: statechange(Pid, What) -> transaction
%% Description: Alter peer identified by Pid by What
%%--------------------------------------------------------------------
statechange(Pid, What) when is_pid(Pid) ->
    F = fun () ->
		[Peer] = mnesia:read(peer, Pid, write),
		NP = alter_state(Peer, What),
		mnesia:write(NP)
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function: is_connected(IP, Port, Id) -> bool()
%% Description: Returns true if we are already connected to this peer.
%%--------------------------------------------------------------------
is_connected(IP, Port, Id) when is_integer(Id) ->
    F = fun () ->
		Q = qlc:q([P || P <- mnesia:table(peer),
				P#peer.ip =:= IP,
				P#peer.port =:= Port,
				P#peer.torrent_id =:= Id]),
		length(qlc:e(Q)) > 0
	end,
    {atomic, B} = mnesia:transaction(F),
    B.


%%--------------------------------------------------------------------
%% Function: reset_round(Id) -> transaction
%% Description: Set Uploaded and Downloaded to 0 for all peers running
%%   on torrent Id.
%%--------------------------------------------------------------------
reset_round(Id) ->
    statechange(Id, reset_round).

%%--------------------------------------------------------------------
%% Function: partition_peers_by_interest(Id) -> {Interested, NotInterested}
%% Description: Consider peers for torrent Id. Return them in 2 blocks: The
%%   interested and the not interested peers.
%%--------------------------------------------------------------------
partition_peers_by_interest(Id) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
	      InterestedQuery = query_interested(true, Id),
	      NotInterestedQuery = query_interested(false, Id),
	      {qlc:e(InterestedQuery), qlc:e(NotInterestedQuery)}
      end).

%%====================================================================
%% Internal functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: query_interested(IsInterested, Id) -> QlcQuery
%% Description: Construct a query selecting all peers with IsInterested.
%%   It is the case that IsInterested should be a bool(). Constrain to
%%   torrent identified by Id
%%--------------------------------------------------------------------
query_interested(IsInterested, Id) ->
    qlc:q([P || P <- mnesia:table(peer),
		P#peer.torrent_id =:= Id,
		P#peer.remote_interested =:= IsInterested]).

%%--------------------------------------------------------------------
%% Function: alter_state(Row, What) -> NewRow
%% Description: Process Row and change it according to a set of valid
%%   transmutations.
%%--------------------------------------------------------------------
alter_state(Peer, What) ->
    case What of
	{optimistic_unchoke, Val} ->
	    Peer#peer{ optimistic_unchoke = Val };
	remove_optimistic_unchoke ->
	    Peer#peer{ optimistic_unchoke = false };
	remote_choking ->
	    Peer#peer{ remote_choking = true};
	remote_unchoking ->
	    Peer#peer{ remote_choking = false};
	interested ->
	    Peer#peer{ remote_interested = true};
	not_intersted ->
	    Peer#peer{ remote_interested = false};
	{uploaded, Amount} ->
	    Uploaded = Peer#peer.uploaded,
	    Peer#peer{ uploaded = Uploaded + Amount };
	{downloaded, Amount} ->
	    Downloaded = Peer#peer.downloaded,
	    Peer#peer{ downloaded = Downloaded + Amount };
	reset_round ->
	    Peer#peer { uploaded = 0, downloaded = 0}
    end.
