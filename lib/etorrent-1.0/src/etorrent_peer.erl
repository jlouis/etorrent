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
-export([new/4, all/1, delete/1, connected/3, ip_port/1, select/1]).

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

%%====================================================================
%% Internal functions
%%====================================================================
