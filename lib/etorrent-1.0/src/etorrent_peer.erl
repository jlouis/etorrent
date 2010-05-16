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
-export([new/5, delete/1, connected/3, select/1, find/1, broadcast_peers/2,
         statechange/2]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: new(IP, Port, InfoHash, Pid) -> transaction
%% Description: Insert a row for the peer
%%--------------------------------------------------------------------
new(IP, Port, TorrentId, Pid, State) ->
    mnesia:dirty_write(#peer { pid = Pid,
                               ip = IP,
                               port = Port,
                               torrent_id = TorrentId,
                               state = State}).

%%--------------------------------------------------------------------
%% Function: statechange(Pid, seeder) -> transaction
%% Description: Change the peer to a seeder
%%--------------------------------------------------------------------
statechange(Pid, seeder) ->
    {atomic, _} = mnesia:transaction(
                    fun () ->
                            [Row] = mnesia:read(peer, Pid, write),
                            mnesia:write(Row#peer { state = seeding })
                    end),
    ok.

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
%% Function: all_pids(Id) -> {value | [#peer]
%% Description: Return all peer pids with a given torrentId
%% TODO: We can probably fetch this from the supervisor tree. There is
%% less reason to have this then.
%%--------------------------------------------------------------------
all_pids(Id) ->
    Pids = mnesia:dirty_index_read(peer, Id, #peer.torrent_id),
    {value, [P#peer.pid || P <- Pids]}.

broadcast_peers(Id, Fun) ->
    {value, Pids} = all_pids(Id),
    lists:foreach(Fun, Pids),
    ok.

%%--------------------------------------------------------------------
%% Function: select(P)
%%           P ::= pid()
%% Description: Select the peer matching pid P.
%%--------------------------------------------------------------------
select(Pid) when is_pid(Pid) ->
    mnesia:dirty_read(peer, Pid).

find(Pid) when is_pid(Pid) ->
    case mnesia:dirty_read(peer, Pid) of
        [] -> not_found;
        [PR] -> {peer_info, PR#peer.state, PR#peer.torrent_id}
    end.


%%====================================================================
%% Internal functions
%%====================================================================
