%%%-------------------------------------------------------------------
%%% File    : etorrent_t_peer_group.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% License : See COPYING
%%% Description : Master process for a number of peers.
%%%
%%% Created : 18 Jul 2007 by
%%%      Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_choker).

-behaviour(gen_server).

-include("rate_mgr.hrl").
-include("peer_state.hrl").

-include("etorrent_mnesia_table.hrl").

%% API
-export([start_link/1, add_peers/2, new_incoming_peer/4, perform_rechoke/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {available_peers = [],
	        bad_peers = none,
		our_peer_id = none,
		info_hash = none,

		num_peers = 0,
		timer_ref = none,
		round = 0,

		optimistic_unchoke_pid = none,
		opt_unchoke_chain = []}).

-record(rechoke_info, {pid :: pid(),
		       kind :: 'seeding' | 'leeching',
		       state :: 'seeding' | 'leeching' ,
		       snubbed :: bool(),
		       r_interest_state :: 'interested' | 'not_interested',
		       r_choke_state :: 'choked' | 'unchoked' ,
		       l_choke :: bool(),
		       rate :: float() }).

-define(SERVER, ?MODULE).
-define(MAX_PEER_PROCESSES, 40).
-define(ROUND_TIME, 10000).

%%====================================================================
%% API
%%====================================================================
start_link(OurPeerId) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [OurPeerId], []).

add_peers(TorrentId, IPList) ->
    gen_server:cast(?SERVER, {add_peers, [{TorrentId, IPP} || IPP <- IPList]}).

perform_rechoke() ->
    gen_server:cast(?SERVER, rechoke).

new_incoming_peer(IP, Port, PeerId, InfoHash) ->
    %% Set a pretty graceful timeout here as the peer_group can be pretty heavily
    %%  loaded at times. We have 5 acceptors by default anyway.
    gen_server:call(?SERVER, {new_incoming_peer, IP, Port, PeerId, InfoHash}, 15000).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([OurPeerId]) ->
    process_flag(trap_exit, true),
    {ok, Tref} = timer:send_interval(?ROUND_TIME, self(), round_tick),
    {ok, #state{ our_peer_id = OurPeerId,
		     bad_peers = dict:new(),
		     timer_ref = Tref}}.


handle_call({new_incoming_peer, _IP, _Port, PeerId, _InfoHash}, _From, S)
  when S#state.our_peer_id =:= PeerId ->
    {reply, connect_to_ourselves, S};
handle_call({new_incoming_peer, IP, Port, _PeerId, InfoHash}, _From, S) ->
    {atomic, [TM]} = etorrent_tracking_map:select({infohash, InfoHash}),
    case etorrent_bad_peer_mgr:is_bad_peer(IP, Port, TM#tracking_map.id) of
	true ->
	    {reply, bad_peer, S};
	false ->
	    start_new_incoming_peer(IP, Port, InfoHash, S)
    end;
handle_call(Request, _From, State) ->
    error_logger:error_report([unknown_peer_group_call, Request]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast({add_peers, IPList}, S) ->
    {ok, NS} = start_new_peers(IPList, S),
    {noreply, NS};
handle_cast(rechoke, S) ->
    rechoke(S),
    {noreply, S};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(round_tick, S) ->
    case S#state.round of
	0 ->
	    {ok, NS} = advance_optimistic_unchoke(S),
	    rechoke(NS),
	    {noreply, NS#state { round = 2}};
	N when is_integer(N) ->
	    rechoke(S),
	    {noreply, S#state{round = S#state.round - 1}}
    end;
handle_info({'DOWN', _Ref, process, Pid, Reason}, S)
  when (Reason =:= normal) or (Reason =:= shutdown) ->
    % The peer shut down normally. Hence we just remove him and start up
    %  other peers. Eventually the tracker will re-add him to the peer list

    % XXX: We might have to do something else
    rechoke(S),

    NewChain = lists:delete(Pid, S#state.opt_unchoke_chain),
    {ok, NS} = start_new_peers([], S#state { num_peers = S#state.num_peers -1,
					     opt_unchoke_chain = NewChain }),
    {noreply, NS};
handle_info({'DOWN', _Ref, process, Pid, _Reason}, S) ->
    % The peer shut down unexpectedly re-add him to the queue in the *back*
    NS = case etorrent_peer:select(Pid) of
	     [Peer] ->
		 {IP, Port} = {Peer#peer.ip, Peer#peer.port},

		 % XXX: We might have to check that remote is intersted and we were choking
		 rechoke(S),
		 S#state { available_peers  = S#state.available_peers ++ [{IP, Port}]};
	     [] -> S
	 end,

    NewChain = lists:delete(Pid, NS#state.opt_unchoke_chain),
    {noreply, NS#state{num_peers = NS#state.num_peers -1,
		      opt_unchoke_chain = NewChain}};
handle_info(Info, State) ->
    error_logger:error_report([unknown_info_peer_group, Info]),
    {noreply, State}.

terminate(Reason, _S) ->
    error_logger:info_report([peer_group_mgr_term, Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

start_new_incoming_peer(IP, Port, InfoHash, S) ->
    case max_peer_processes() - S#state.num_peers of
	N when N =< 0 ->
	    {reply, already_enough_connections, S};
	N when is_integer(N), N > 0 ->
	    {atomic, [T]} = etorrent_tracking_map:select({infohash, InfoHash}),
	    {ok, Pid} = etorrent_t_sup:add_peer(
			  T#tracking_map.supervisor_pid,
			  S#state.our_peer_id,
			  InfoHash,
			  T#tracking_map.id,
			  {IP, Port}),
	    erlang:monitor(process, Pid),
	    NewChain = insert_new_peer_into_chain(Pid, S#state.opt_unchoke_chain),
	    rechoke(S),
	    {reply, {ok, Pid},
	     S#state { num_peers = S#state.num_peers+1,
		       opt_unchoke_chain = NewChain}}
    end.


start_new_peers(IPList, State) ->
    %% Update the PeerList with the new incoming peers
    PeerList = lists:usort(IPList ++ State#state.available_peers),
    S = State#state { available_peers = PeerList},

    %% Replenish the connected peers.
    fill_peers(max_peer_processes() - S#state.num_peers, S).

%%% NOTE: fill_peers/2 and spawn_new_peer/5 tail calls each other.
fill_peers(0, S) ->
    {ok, S};
fill_peers(N, S) ->
    case S#state.available_peers of
	[] ->
	    % No peers available, just stop trying to fill peers
	    {ok, S};
	[{TorrentId, {IP, Port}} | R] ->
	    % Possible peer. Check it.
	    case etorrent_bad_peer_mgr:is_bad_peer(IP, Port, TorrentId) of
		true ->
		    fill_peers(N, S#state{available_peers = R});
		false ->
		    spawn_new_peer(IP, Port, TorrentId, N, S#state{available_peers = R})
	    end
    end.

%%--------------------------------------------------------------------
%% Function: spawn_new_peer(IP, Port, N, S) -> {ok, State}
%% Description: Attempt to spawn the peer at IP/Port. N is the number of
%%   peers we still need to spawn and S is the current state. Returns
%%   a new state to be put into the process.
%%--------------------------------------------------------------------
spawn_new_peer(IP, Port, TorrentId, N, S) ->
    case etorrent_peer:connected(IP, Port, TorrentId) of
	true ->
	    fill_peers(N, S);
	false ->
	    {atomic, [TM]} = etorrent_tracking_map:select(TorrentId),
	    {ok, Pid} = etorrent_t_sup:add_peer(
			  TM#tracking_map.supervisor_pid,
			  S#state.our_peer_id,
			  TM#tracking_map.info_hash,
			  TorrentId,
			  {IP, Port}),
	    erlang:monitor(process, Pid),
	    etorrent_t_peer_recv:connect(Pid, IP, Port),
	    NewChain = insert_new_peer_into_chain(Pid, S#state.opt_unchoke_chain),
	    rechoke(S),
	    fill_peers(N-1, S#state { num_peers = S#state.num_peers +1,
				      opt_unchoke_chain = NewChain})
    end.

%%--------------------------------------------------------------------
%% Function: rechoke(State) -> ok
%% Description: Recalculate the choke/unchoke state of peers
%%--------------------------------------------------------------------
rechoke(S) ->
    Peers = build_rechoke_info(S#state.opt_unchoke_chain),
    {PreferredDown, PreferredSeed} = split_preferred(Peers),
    PreferredSet = prune_preferred_peers(PreferredDown, PreferredSeed),
    {N, ToChoke} = rechoke_unchoke(Peers, PreferredSet, 0, []),
    rechoke_choke(ToChoke, N, optimistics(PreferredSet)).

build_rechoke_info(Peers) ->
    SeederSet = sets:from_list(seeding_torrents()),
    build_rechoke_info(SeederSet, Peers).

build_rechoke_info(_Seeding, []) ->
    [];
build_rechoke_info(Seeding, [Pid | Next]) ->
    case etorrent_peer:select(Pid) of
	[] -> build_rechoke_info(Seeding, Next);
	[Peer] ->
	    Kind = Peer#peer.state,
	    Snubbed = etorrent_rate_mgr:snubbed(Peer#peer.torrent_id, Pid),
	    PeerState = etorrent_rate_mgr:select_state(Peer#peer.torrent_id, Pid),
	    case sets:is_element(Peer#peer.torrent_id, Seeding) of
		true ->
		    case etorrent_rate_mgr:fetch_send_rate(
			   Peer#peer.torrent_id,
			   Pid) of
			none -> build_rechoke_info(Seeding, Next);
			Rate ->
			    [#rechoke_info { pid = Pid,
					     kind = Kind,
					     state = seeding,
					     rate = Rate,
					     r_interest_state =
					       PeerState#peer_state.interest_state,
					     r_choke_state =
					       PeerState#peer_state.choke_state,
					     l_choke =
					       PeerState#peer_state.local_choke,
					     snubbed = Snubbed } |
			     build_rechoke_info(Seeding, Next)]
		    end;
		false ->
		    case etorrent_rate_mgr:fetch_recv_rate(
			   Peer#peer.torrent_id,
			   Pid) of
			none -> build_rechoke_info(Seeding, Next);
			Rate ->
			    [#rechoke_info { pid = Pid,
					     kind = Kind,
					     state = leeching,
					     rate = -Rate, % Inverted for later sorting!
					     snubbed = Snubbed } |
			     build_rechoke_info(Seeding, Next)]
		    end
	    end
    end.

advance_optimistic_unchoke(S) ->
    NewChain = move_cyclic_chain(S#state.opt_unchoke_chain),
    case NewChain of
	[] ->
	    {ok, S}; %% No peers yet
	[H | _T] ->
	    etorrent_t_peer_recv:unchoke(H),
	    {ok, S#state { opt_unchoke_chain = NewChain,
			   optimistic_unchoke_pid = H }}
    end.

move_cyclic_chain([]) -> [];
move_cyclic_chain(Chain) ->
    F = fun (Pid) ->
		case etorrent_peer:select(Pid) of
		    [] -> true;
		    [P] -> T = etorrent_rate_mgr:select_state(
				 P#peer.torrent_id,
				 Pid),
			   T#peer_state.interest_state =:= interested
			       andalso T#peer_state.choke_state =:= choked
		end
	end,
    {Front, Back} = lists:splitwith(F, Chain),
    %% Advance chain
    Back ++ Front.

insert_new_peer_into_chain(Pid, Chain) ->
    Length = length(Chain),
    Index = lists:max([0, crypto:rand_uniform(0, Length)]),
    {Front, Back} = lists:split(Index, Chain),
    Front ++ [Pid | Back].

max_peer_processes() ->
    case application:get_env(etorrent, max_peers) of
	{ok, N} when is_integer(N) ->
	    N;
	undefined ->
	    ?MAX_PEER_PROCESSES
    end.

upload_slots() ->
    case application:get_env(etorrent, max_upload_slots) of
	{ok, auto} ->
	    {ok, Rate} = application:get_env(etorrent, max_upload_rate),
	    case Rate of
		N when N =<  0 -> 7; %% Educated guess
		N when N  <  9 -> 2;
		N when N  < 15 -> 3;
		N when N  < 42 -> 4;
		N ->
		    round(math:sqrt(N * 0.6))
	    end;
	{ok, N} when is_integer(N) ->
	    N
    end.

split_preferred(Peers) ->
    {Downs, Leechs} = split_preferred_peers(Peers, [], []),
    {lists:keysort(#rechoke_info.rate, Downs),
     lists:keysort(#rechoke_info.rate, Leechs)}.

prune_preferred_peers(SDowns, SLeechs) ->
    MaxUploads = upload_slots(),
    DUploads = lists:max([1, round(MaxUploads * 0.7)]),
    SUploads = lists:max([1, round(MaxUploads * 0.3)]),
    {SUP2, DUP2} =
	case lists:max([0, DUploads - length(SDowns)]) of
	    0 -> {SUploads, DUploads};
	    N -> {SUploads + N, DUploads - N}
	end,
    {SUP3, DUP3} =
	case lists:max([0, SUP2 - length(SLeechs)]) of
	    0 -> {SUP2, DUP2};
	    K ->
		{SUP2 - K, lists:min([DUP2 + K, length(SDowns)])}
	end,
    {TSDowns, TSLeechs} = {lists:sublist(SDowns, DUP3),
			   lists:sublist(SLeechs, SUP3)},
    sets:union(sets:from_list(TSDowns), sets:from_list(TSLeechs)).

rechoke_unchoke([], _PS, Count, ToChoke) ->
    {Count, ToChoke};
rechoke_unchoke([P | Next], PSet, Count, ToChoke) ->
    case sets:is_element(P, PSet) of
	true ->
	    etorrent_t_peer_recv:unchoke(P#rechoke_info.pid),
	    rechoke_unchoke(Next, PSet, Count+1, ToChoke);
	false ->
	    rechoke_unchoke(Next, PSet, Count+1, [P | ToChoke])
    end.

optimistics(PSet) ->
    MinUp = case application:get_env(etorrent, min_uploads) of
		{ok, N} -> N;
		undefined -> 1
	    end,
    lists:max([MinUp, upload_slots() - sets:size(PSet)]).

rechoke_choke([], _Count, _Optimistics) ->
    ok;
rechoke_choke([P | Next], Count, Optimistics) when Count >= Optimistics ->
    etorrent_t_peer_recv:choke(P#rechoke_info.pid),
    rechoke_choke(Next, Count, Optimistics);
rechoke_choke([P | Next], Count, Optimistics) ->
    case P#rechoke_info.kind =:= seeding of
	true ->
	    etorrent_t_peer_recv:choke(P#rechoke_info.pid),
	    rechoke_choke(Next, Count, Optimistics);
	false ->
	    etorrent_t_peer_recv:unchoke(P#rechoke_info.pid),
	    case P#rechoke_info.r_interest_state =:= interested of
		true ->
		    rechoke_choke(Next, Count+1, Optimistics);
		false ->
		    rechoke_choke(Next, Count, Optimistics)
	    end
    end.

split_preferred_peers([], Downs, Leechs) ->
    {Downs, Leechs};
split_preferred_peers([P | Next], Downs, Leechs) ->
    case P#rechoke_info.state =:= seeding
	  orelse P#rechoke_info.r_interest_state =:= not_interested of
	true ->
	    split_preferred_peers(Next, Downs, Leechs);
	false when P#rechoke_info.state =:= seeding ->
	    split_preferred_peers(Next, Downs, [P | Leechs]);
	false when P#rechoke_info.snubbed =:= true ->
	    split_preferred_peers(Next, Downs, Leechs);
	false ->
	    split_preferred_peers(Next, [P | Downs], Leechs)
    end.

seeding_torrents() ->
    {atomic, Torrents} = etorrent_torrent:all(),
    [T || T <- Torrents,
	  T#torrent.state =:= seeding].
