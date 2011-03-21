% @doc The interface to query the Erlang system for values in general
-module(etorrent_query).

-export([
         log_list/0,
         peer_list/0,
         torrent_list/0
        ]).

log_list() ->
    Entries = etorrent_memory_logger:all_entries(),
    [format_log_entry(E) || E <- Entries].

format_log_entry({_Now, LTime, Event}) ->
    EventStr = io_lib:format("~p", [Event]),
    [{time, iolist_to_binary(etorrent_utils:date_str(LTime))},
     {event, iolist_to_binary(EventStr)}].

torrent_list() ->
    All = etorrent_torrent:all(),
    All.

peer_list() ->
    AllPeers = etorrent_table:all_peers(),
    PeerState = etorrent_peer_states:all_peers(),
    merge_peer_states(AllPeers, PeerState).

merge_peer_states(PeerList, StateList) ->
    merge_by(lists:sort(
               fun(P1, P2) ->
                       proplists:get_value(pid, P1) =< proplists:get_value(pid, P2)
               end,
               PeerList),
             lists:sort(
               fun(SL1, SL2) ->
                       proplists:get_value(pid, SL1) =< proplists:get_value(pid, SL2)
               end,
               StateList),
             fun(Item1, Item2) ->
                     {E1, E2} = {proplists:get_value(pid, Item1), proplists:get_value(pid, Item2)},
                     if
                         E1 == E2 -> equal;
                         E1 =< E2 -> less;
                         E1 >= E2 -> greater
                     end
             end,
             fun (I1, I2) ->
                     Merged = lists:umerge(I1, I2),
                     {B1, B2, B3, B4} = proplists:get_value(ip, Merged),

                     Cleaned = proplists:delete(ip,
                                proplists:delete(pid,
                                 Merged)),
                     proplists:normalize(
                       [{ip, iolist_to_binary(io_lib:format("~B.~B.~B.~B", [B1, B2, B3, B4]))}] ++
                           Cleaned, [])
             end).

merge_by([], _, _, _) -> [];
merge_by(_, [], _, _) -> [];
merge_by([], [], _CompareFun, _MergeFun) -> [];
merge_by([I1 | R1], [I2 | R2], CompareFun, MergeFun) ->
    case CompareFun(I1, I2) of
        less ->
            merge_by(R1, [I2 | R2], CompareFun, MergeFun);
        greater ->
            merge_by([I1 | R1], R2, CompareFun, MergeFun);
        equal ->
             [MergeFun(I1, I2) | merge_by(R1, R2, CompareFun, MergeFun)]
    end.




