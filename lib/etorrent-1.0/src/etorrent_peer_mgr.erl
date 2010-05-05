%%%-------------------------------------------------------------------
%%% File    : etorrent_bad_peer_mgr.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Peer management server
%%%
%%% Created : 19 Jul 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------

%%% TODO: Monitor peers and retry them. In general, we need peer management here.
-module(etorrent_peer_mgr).

-include("etorrent_mnesia_table.hrl").
-include("etorrent_bad_peer.hrl").

-behaviour(gen_server).

%% API
-export([start_link/1, enter_bad_peer/3, bad_peer_list/0, add_peers/2,
         is_bad_peer/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, { our_peer_id,
                 available_peers = []}).

-define(SERVER, ?MODULE).
-define(DEFAULT_BAD_COUNT, 2).
-define(GRACE_TIME, 900).
-define(CHECK_TIME, timer:seconds(300)).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(OurPeerId) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [OurPeerId], []).

enter_bad_peer(IP, Port, PeerId) ->
    gen_server:cast(?SERVER, {enter_bad_peer, IP, Port, PeerId}).

add_peers(TorrentId, IPList) ->
    gen_server:cast(?SERVER, {add_peers,
                              [{TorrentId, {IP, Port}} || {IP, Port} <- IPList]}).

%% Returns true if this peer is in the list of baddies
is_bad_peer(IP, Port) ->
    case ets:lookup(etorrent_bad_peer, {IP, Port}) of
        [] -> false;
        [P] -> P#bad_peer.offenses > ?DEFAULT_BAD_COUNT
    end.

bad_peer_list() ->
    ets:match(etorrent_bad_peer, '_').

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([OurPeerId]) ->
    process_flag(trap_exit, true),
    _Tref = timer:send_interval(?CHECK_TIME, self(), cleanup_table),
    _Tid = ets:new(etorrent_bad_peer, [set, protected, named_table,
                                       {keypos, #bad_peer.ipport}]),
    {ok, #state{ our_peer_id = OurPeerId }}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
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

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(cleanup_table, S) ->
    Bound = etorrent_time:now_subtract_seconds(now(), ?GRACE_TIME),
    _N = ets:select_delete(etorrent_bad_peer,
                           [{#bad_peer { last_offense = '$1', _='_'},
                             [{'<','$1',{Bound}}],
                             [true]}]),
    {noreply, S};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ets:delete(etorrent_bad_peer),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------


start_new_peers(IPList, State) ->
    %% Update the PeerList with the new incoming peers
    PeerList = lists:usort(IPList ++ State#state.available_peers),
    S = State#state { available_peers = PeerList},

    %% Replenish the connected peers.
    fill_peers(S).

%%% NOTE: fill_peers/2 and spawn_new_peer/5 tail calls each other.
fill_peers(S) ->
    case S#state.available_peers of
        [] ->
            % No peers available, just stop trying to fill peers
            S;
        [{TorrentId, {IP, Port}} | R] ->
            % Possible peer. Check it.
            case is_bad_peer(IP, Port) of
                true ->
                    fill_peers(S#state{available_peers = R});
                false ->
                    case etorrent_peer:connected(IP, Port, TorrentId) of
                        true ->
                            fill_peers(S#state{available_peers = R});
                        false ->
                            error_logger:info_report([spawning, {ip, IP},
                                                      {port, Port}, {tid, TorrentId}]),
                            spawn_new_peer(IP, Port, TorrentId,
                                           S#state{available_peers = R})
                    end
            end
    end.

%%--------------------------------------------------------------------
%% Function: spawn_new_peer(IP, Port, S) -> S
%%  Args:   IP ::= ip_address()
%%          Port ::= integer() (16-bit)
%%          S :: #state()
%% Description: Attempt to spawn the peer at IP/Port. Returns modified state.
%%--------------------------------------------------------------------
spawn_new_peer(IP, Port, TorrentId, S) ->
    case etorrent_peer:connected(IP, Port, TorrentId) of
        true ->
            fill_peers(S);
        false ->
            {atomic, [TM]} = etorrent_tracking_map:select(TorrentId),
            case etorrent_counters:obtain_peer_slot() of
                ok ->
                    try
                        {ok, Pid} = etorrent_t_sup:add_peer(
                                      TM#tracking_map.supervisor_pid,
                                      S#state.our_peer_id,
                                      TM#tracking_map.info_hash,
                                      TorrentId,
                                      {IP, Port}),
                        ok = etorrent_t_peer_recv:connect(Pid, IP, Port)
                    catch
                        throw:_ -> etorrent_counters:release_peer_slot();
                        exit:_ ->  etorrent_counters:release_peer_slot()
                    end,
                    fill_peers(S);
                full ->
                    S
            end
    end.

