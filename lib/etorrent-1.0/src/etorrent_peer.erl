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
-export([new/4, all/1, delete/1, statechange/2, connected/3,
	 ip_port/1, select_fastest/2, interested/1, local_unchoked/1,
	 select/1]).

%%====================================================================
%% API
%%====================================================================
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
%% Function: ip_port(Pid) -> {IP, Port}
%% Description: Select the IP and Port pair of a Pid
%%--------------------------------------------------------------------
ip_port(Pid) ->
    [R] = mnesia:dirty_read(peer, Pid),
    {R#peer.ip, R#peer.port}.

%%--------------------------------------------------------------------
%% Function: delete(Pid) -> ok | {aborted, Reason}
%% Description: Delete all references to the peer owned by Pid
%%--------------------------------------------------------------------
delete(Id) when is_integer(Id) ->
    [mnesia:dirty_delete_object(Peer) ||
	Peer <- mnesia:dirty_index_read(peer, Id, #peer.torrent_id)];
delete(Pid) when is_pid(Pid) ->
    mnesia:dirty_delete(peer, Pid).

%%--------------------------------------------------------------------
%% Function: statechange(Id, What) -> transaction
%%           Id ::= none | integer()
%% Description: Alter all peers matching torrent Id by What. The 'none'
%%   case allows us to gracefully handle some corner cases.
%%--------------------------------------------------------------------
statechange(none, _What) -> {atomic, ok};
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
statechange(Peer, What) when is_record(Peer, peer) ->
    statechange(Peer#peer.pid, What);
statechange(Pid, What) when is_pid(Pid) ->
    F = fun () ->
		[Peer] = mnesia:read(peer, Pid, write),
		NP = alter_state(Peer, What),
		mnesia:write(NP)
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function: connected(IP, Port, Id) -> bool()
%% Description: Returns true if we are already connected to this peer.
%%--------------------------------------------------------------------
connected(IP, Port, Id) when is_integer(Id) ->
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
%% Function: all(Id) -> [#peer]
%% Description: Return all peers with a given Id
%%--------------------------------------------------------------------
all(Id) ->
    mnesia:dirty_index_read(peer, Id, #peer.torrent_id).

%%--------------------------------------------------------------------
%% Function: select(P)
%%           P ::= pid()
%% Description: Select the peer matching pid P.
%%--------------------------------------------------------------------
select(Pid) when is_pid(Pid) ->
    mnesia:dirty_read(peer, Pid).

%%--------------------------------------------------------------------
%% Function: select_fastest(Id, Key) -> [#peer]
%%           Interest ::= interested | not_interested
%%           Key      ::= integer()
%% Description: Select the fastest peers matching the query
%%--------------------------------------------------------------------
select_fastest(TorrentId, Key) ->
    mnesia:transaction(
      fun () ->
	      QH = qlc:q([P || P <- mnesia:table(peer),
			       P#peer.torrent_id =:= TorrentId]),
	      qlc:e(qlc:keysort(Key, QH, {order, descending}))
      end).

%%--------------------------------------------------------------------
%% Function: local_unchoked(P) -> bool()
%%           P ::= pid()
%% Description: Predicate: P is unchoked locally.
%%--------------------------------------------------------------------
local_unchoked(P) ->
    [R] = mnesia:dirty_read(peer, P),
    case R#peer.local_c_state of
	choked ->
	    false;
	unchoked ->
	    true
    end.

%%--------------------------------------------------------------------
%% Function: interested(P) -> bool()
%%           P ::= none | pid()
%% Description: Query the remote interest state on P
%%--------------------------------------------------------------------
interested(none) -> false;
interested(P) when is_pid(P) ->
    case mnesia:dirty_read(peer, P) of
	[] ->
	    false;
	[_] ->
	    true
    end.

%%====================================================================
%% Internal functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: alter_state(Row, What) -> NewRow
%% Description: Process Row and change it according to a set of valid
%%   transmutations.
%%--------------------------------------------------------------------
alter_state(Peer, What) ->
    case What of
	optimistic_unchoke ->
	    Peer#peer{ optimistic_c_state = opt_unchoke };
	remove_optimistic_unchoke ->
	    Peer#peer{ optimistic_c_state = not_opt_unchoke };
	remote_choking ->
	    Peer#peer{ remote_c_state = choked};
	remote_unchoking ->
	    Peer#peer{ remote_c_state = unchoked};
	local_choking ->
	    Peer#peer { local_c_state = choked };
	local_unchoking ->
	    Peer#peer { local_c_state = unchoked };
	interested ->
	    Peer#peer{ remote_i_state = interested};
	not_interested ->
	    Peer#peer{ remote_i_state = not_interested};
	{download_rate, Rate} ->
	    Peer#peer { download_rate = Rate };
	{upload_rate, Rate} ->
	    Peer#peer { upload_rate = Rate }
    end.
