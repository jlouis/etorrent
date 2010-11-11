-module(etorrent_dht_tracker).
-behaviour(gen_server).
-include("types.hrl").
-export([start_link/0,
         start_link/2,
         announce/1,
         tab_name/0,
         announce/3,
         get_peers/1]).

-spec start_link(infohash(), integer()) -> {'ok', pid()}.
-spec announce(pid()) -> 'ok'.
-spec announce(infohash(), ipaddr(), portnum()) -> 'ok'.
-spec get_peers(infohash()) -> list(peerinfo()).

-record(state, {
    infohash :: infohash(),
    torrentid :: integer(),
    interval=10*60*1000,
    timer_ref}).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

tab_name() ->
    etorrent_dht_tracker_tab.

max_per_torrent() ->
    32.

start_link() ->
    _ = case ets:info(tab_name()) of
        undefined -> ets:new(tab_name(), [named_table, public, bag]);
        _ -> ok
    end.

start_link(InfoHash, TorrentID) ->
    Args = [{infohash, InfoHash}, {torrentid, TorrentID}],
    gen_server:start_link(?MODULE, Args, []).

announce(TrackerPid) ->
    gen_server:cast(TrackerPid, announce).
    

%
% Register a peer as a member of a swarm. If the maximum number of
% registered peers for a torrent is exceeded, one or more peers are
% deleted.
%
announce(InfoHash, {_,_,_,_}=IP, Port) when is_integer(InfoHash), is_integer(Port) ->
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


random_peer() ->
    random:seed(now()),
    random:uniform(max_per_torrent()).

init(Args) ->
    InfoHash  = proplists:get_value(infohash, Args),
    TorrentID = proplists:get_value(torrentid, Args),
    _ = gen_server:cast(self(), init_timer),
    _ = gen_server:cast(self(), announce),
    InitState = #state{infohash=InfoHash, torrentid=TorrentID},
    {ok, InitState}.

handle_call(_, _, State) ->
    {reply, not_implemented, State}.

handle_cast(init_timer, State) ->
    #state{interval=Interval} = State,
    {ok, TRef} = timer:apply_interval(Interval, ?MODULE, announce, [self()]),
    NewState   = State#state{timer_ref=TRef},
    {noreply, NewState};

handle_cast(announce, State) ->
    #state{
        infohash=InfoHash,
        torrentid=_TorrentID} = State,
    {_, Peers, _} = etorrent_dht_net:get_peers_search(InfoHash),
    error_logger:info_msg("Found ~w peers", [length(Peers)]),

    {noreply, State}.

handle_info(_, State) ->
    {noreply, State}.

terminate(_, State) ->
    #state{timer_ref=TRef} = State,
    timer:cancel(TRef).

code_change(_, State, _) ->
    {ok, State}.
