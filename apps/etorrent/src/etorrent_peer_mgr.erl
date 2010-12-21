%%%-------------------------------------------------------------------
%%% File    : etorrent_bad_peer_mgr.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Peer management server
%%%
%%% Created : 19 Jul 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------

%%% @todo: Monitor peers and retry them. In general, we need peer management here.
-module(etorrent_peer_mgr).

-include("etorrent_bad_peer.hrl").
-include("types.hrl").

-behaviour(gen_server).

%% API
-export([start_link/1, enter_bad_peer/3, add_peers/2, is_bad_peer/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, { our_peer_id,
                 available_peers = []}).
-ignore_xref([{'start_link', 1}]).
-define(SERVER, ?MODULE).
-define(DEFAULT_BAD_COUNT, 2).
-define(GRACE_TIME, 900).
-define(CHECK_TIME, timer:seconds(120)).
-define(DEFAULT_CONNECT_TIMEOUT, 30 * 1000).

%% ====================================================================
% @doc Start the peer manager
% @end
-spec start_link(binary()) -> {ok, pid()} | ignore | {error, term()}.
start_link(OurPeerId) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [OurPeerId], []).

% @doc Tell the peer mananger that a given peer behaved badly.
% @end
-spec enter_bad_peer(ip(), integer(), binary()) -> ok.
enter_bad_peer(IP, Port, PeerId) ->
    gen_server:cast(?SERVER, {enter_bad_peer, IP, Port, PeerId}).

% @doc Add a list of {IP, Port} peers to the manager.
% <p>The manager will use the list of peers for connections to other peers. It
% may not use all of those given if it deems it has enough connections right
% now.</p>
% @end
-spec add_peers(integer(), [{ip(), integer()}]) -> ok.
add_peers(TorrentId, IPList) ->
    gen_server:cast(?SERVER, {add_peers,
                              [{TorrentId, {IP, Port}} || {IP, Port} <- IPList]}).

% @doc Returns true if this peer is in the list of baddies
% @end
-spec is_bad_peer(ip(), integer()) -> boolean().
is_bad_peer(IP, Port) ->
    case ets:lookup(etorrent_bad_peer, {IP, Port}) of
        [] -> false;
        [P] -> P#bad_peer.offenses > ?DEFAULT_BAD_COUNT
    end.

%% ====================================================================

init([OurPeerId]) ->
    erlang:send_after(?CHECK_TIME, self(), cleanup_table),
    _Tid = ets:new(etorrent_bad_peer, [protected, named_table,
                                       {keypos, #bad_peer.ipport}]),
    {ok, #state{ our_peer_id = OurPeerId }}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast({add_peers, IPList}, S) ->
    NS = start_new_peers(IPList, S),
    {noreply, NS};
handle_cast({enter_bad_peer, IP, Port, PeerId}, S) ->
    case ets:lookup(etorrent_bad_peer, {IP, Port}) of
        [] ->
            ets:insert(etorrent_bad_peer,
                       #bad_peer { ipport = {IP, Port},
                                   peerid = PeerId,
                                   offenses = 1,
                                   last_offense = now() });
        [P] ->
            ets:insert(etorrent_bad_peer,
                       P#bad_peer { offenses = P#bad_peer.offenses + 1,
                                    peerid = PeerId,
                                    last_offense = now() })
    end,
    {noreply, S};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(cleanup_table, S) ->
    Bound = etorrent_utils:now_subtract_seconds(now(), ?GRACE_TIME),
    _N = ets:select_delete(etorrent_bad_peer,
                           [{#bad_peer { last_offense = '$1', _='_'},
                             [{'<','$1',{Bound}}],
                             [true]}]),
    gen_server:cast(?SERVER, {add_peers, []}),
    erlang:send_after(?CHECK_TIME, self(), cleanup_table),
    {noreply, S};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% --------------------------------------------------------------------

start_new_peers(IPList, State) ->
    %% Update the PeerList with the new incoming peers
    %% XXX:
    %%   the usort is potentially a bad idea here. It will sort the list
    %%   and thus mostly take IP addresses in a specific order. This is
    %%   a bad idea for various reasons.
    %%
    %%   A nice change would be to do duplicate removal the right way
    %%   on the unsorted list.
    PeerList = lists:usort(IPList ++ State#state.available_peers),
    PeerId   = State#state.our_peer_id,
    {value, SlotsLeft} = etorrent_counters:slots_left(),
    Remaining = fill_peers(SlotsLeft, PeerId, PeerList),
    State#state{available_peers = Remaining}.

fill_peers(0, _PeerId, Rem) -> Rem;
fill_peers(_K, _PeerId, []) -> [];
fill_peers(K, PeerId, [{TorrentId, {IP, Port}} | R]) ->
    case is_bad_peer(IP, Port) of
       true -> fill_peers(K, PeerId, R);
       false -> guard_spawn_peer(K, PeerId, TorrentId, IP, Port, R)
    end.

guard_spawn_peer(K, PeerId, TorrentId, IP, Port, R) ->
    case etorrent_table:connected_peer(IP, Port, TorrentId) of
        true ->
            % Already connected to the peer. This happens
            % when the peer connects back to us and the
            % tracker, which knows nothing about this,
            % still hands us the ip address.
            fill_peers(K, PeerId, R);
        false ->
            case etorrent_table:get_torrent(TorrentId) of
		not_found -> %% No such Torrent currently started, skip
		    fill_peers(K, PeerId, R);
                {value, PL} ->
                    try_spawn_peer(K, PeerId, PL, TorrentId, IP, Port, R)
            end
    end.

try_spawn_peer(K, PeerId, PL, TorrentId, IP, Port, R) ->
    spawn_peer(PeerId, PL, TorrentId, IP, Port),
    fill_peers(K-1, PeerId, R).

spawn_peer(PeerId, PL, TorrentId, IP, Port) ->
    spawn(fun () ->
      case gen_tcp:connect(IP, Port, [binary, {active, false}],
			   ?DEFAULT_CONNECT_TIMEOUT) of
	  {ok, Socket} ->
	      case etorrent_proto_wire:initiate_handshake(
		     Socket,
		     PeerId,
		     proplists:get_value(info_hash, PL)) of
		  {ok, _Capabilities, PeerId} -> ok;
		  {ok, Capabilities, RPID} ->
		      {ok, RecvPid, ControlPid} =
			  etorrent_t_sup:add_peer(
			    RPID,
			    proplists:get_value(info_hash, PL),
			    TorrentId,
			    {IP, Port},
			    Capabilities,
			    Socket),
		      ok = gen_tcp:controlling_process(Socket, RecvPid),
		      etorrent_peer_control:initialize(ControlPid, outgoing),
		      ok;
		  {error, _Reason} -> ok
	      end;
	  {error, _Reason} -> ok
      end
   end).
