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

announce(InfoHash, IP, Port) ->
    % Limit the amount of peers associated to a torrent to 80 entries.
    MSpec = [{{{peer,InfoHash},'$1','$2'}, [], [{{{{peer,InfoHash}},'$1','$2'}}]}],
    case ets:select(tab_name(), MSpec, 79) of
        '$end_of_table' ->
            announce(InfoHash, IP, Port, '$end_of_table');
        {_, Cont} ->
            announce(InfoHash, IP, Port, Cont)
    end.

announce(InfoHash, IP, Port, '$end_of_table') ->
    Key = {peer, InfoHash},
    Obj = {Key, IP, Port},
    ets:insert(tab_name(), Obj);

announce(InfoHash, IP, Port, Continuation) ->
    {Peers, NextCont} = ets:select(Continuation),
    _ = [ets:delete_object(tab_name(), P) || P <- Peers],
    announce(InfoHash, IP, Port, NextCont).


get_peers(InfoHash) ->
    case ets:select(tab_name(), [{{{peer,InfoHash},'$1','$2'},[],[{{'$1','$2'}}]}], 80) of
        {PeerInfos, _} -> PeerInfos;
        '$end_of_table' -> []
    end.
