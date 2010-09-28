-module(etorrent_dht_tracker).
-export([init/0,
         tab_name/0,
         announce/3,
         get_peers/1]).

tab_name() ->
    etorrent_dht_tracker_tab.


init() ->
    case ets:info(tab_name()) of
        undefined ->
            _ = ets:new(tab_name(), [named_table, public, bag]),
            ok;
        _ ->
            ok
    end.

%
% Register a peer as a member of a swarm. If the maximum number of
% registered peers for a torrent is exceeded, one or more peers are
% deleted.
%
announce(InfoHash, IP, Port) ->
    % Always delete a random peer when inserting a new
    % peer into the table. If limit is not reached yet, the
    % chances of deleting a peer for no good reason are lower.
    RandPeer = random_peer(),
    DelSpec  = [{{InfoHash,'$1','$2',RandPeer},[],[true]}],
    _ = ets:select_delete(tab_name(), DelSpec),
    ets:insert(tab_name(), {InfoHash, IP, Port, RandPeer}).
       
   

%
% Get the peers that are registered as members of this swarm.
%
get_peers(InfoHash) ->
    GetSpec = [{{InfoHash,'$1','$2','_'},[],[{{'$1','$2'}}]}],
    case ets:select(tab_name(), GetSpec, max_per_torrent()) of
        {PeerInfos, _} -> PeerInfos;
        '$end_of_table' -> []
    end.

max_per_torrent() ->
    32.

random_peer() ->
    random:uniform(max_per_torrent()).
