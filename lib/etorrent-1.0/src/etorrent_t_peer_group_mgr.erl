%%%-------------------------------------------------------------------
%%% File    : etorrent_t_peer_group.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% License : See COPYING
%%% Description : Master process for a number of peers.
%%%
%%% Created : 18 Jul 2007 by
%%%      Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------

-module(etorrent_t_peer_group_mgr).

-behaviour(gen_server).

-include("etorrent_mnesia_table.hrl").

%% API
-export([start_link/5, add_peers/2, broadcast_have/2, new_incoming_peer/3,
	 broadcast_got_chunk/2, perform_rechoke/1]).

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
		opt_unchoke_chain = [],

	        file_system_pid = none,
		peer_group_sup = none,
		torrent_id = none}).

-define(MAX_PEER_PROCESSES, 40).
-define(ROUND_TIME, 10000).
-define(DEFAULT_NUM_DOWNLOADERS, 4).

%%====================================================================
%% API
%%====================================================================
start_link(OurPeerId, PeerGroup, InfoHash,
	   FileSystemPid, TorrentHandle) ->
    gen_server:start_link(?MODULE, [OurPeerId, PeerGroup, InfoHash,
				    FileSystemPid, TorrentHandle], []).

add_peers(Pid, IPList) ->
    gen_server:cast(Pid, {add_peers, IPList}).

broadcast_have(Pid, Index) ->
    gen_server:cast(Pid, {broadcast_have, Index}).

broadcast_got_chunk(Pid, Chunk) ->
    gen_server:cast(Pid, {broadcast_got_chunk, Chunk}).

perform_rechoke(Pid) ->
    gen_server:cast(Pid, rechoke).

new_incoming_peer(Pid, IP, Port) ->
    %% Set a pretty graceful timeout here as the peer_group can be pretty heavily
    %%  loaded at times. We have 5 acceptors by default anyway.
    gen_server:call(Pid, {new_incoming_peer, IP, Port}, 15000).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([OurPeerId, PeerGroup, InfoHash,
      FileSystemPid, TorrentId]) when is_integer(TorrentId) ->
    process_flag(trap_exit, true),
    {ok, Tref} = timer:send_interval(?ROUND_TIME, self(), round_tick),
    {ok, #state{ our_peer_id = OurPeerId,
		 peer_group_sup = PeerGroup,
		 bad_peers = dict:new(),
		 info_hash = InfoHash,
		 timer_ref = Tref,
		 torrent_id = TorrentId,
		 file_system_pid = FileSystemPid}}.

handle_call({new_incoming_peer, IP, Port}, _From, S) ->
    case is_bad_peer(IP, Port, S) of
	true ->
	    {reply, bad_peer, S};
	false ->
	    start_new_incoming_peer(IP, Port, S)
    end;
handle_call(Request, _From, State) ->
    error_logger:error_report([unknown_peer_group_call, Request]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast({add_peers, IPList}, S) ->
    {ok, NS} = start_new_peers(IPList, S),
    {noreply, NS};
handle_cast({broadcast_have, Index}, S) ->
    broadcast_have_message(Index, S),
    {noreply, S};
handle_cast({broadcast_got_chunk, Chunk}, S) ->
    bcast_got_chunk(Chunk, S),
    {noreply, S};
handle_cast(rechoke, S) ->
    rechoke(S),
    {noreply, S};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(round_tick, S) ->
    case S#state.round of
	0 ->
	    NS = advance_optimistic_unchoke(S),
	    rechoke(NS),
	    {atomic, _} = etorrent_peer:reset_round(S#state.torrent_id),
	    {noreply, NS#state { round = 2}};
	N when is_integer(N) ->
	    rechoke(S),
	    {atomic, _} = etorrent_peer:reset_round(S#state.torrent_id),
	    {noreply, S#state{round = S#state.round - 1}}
    end;
handle_info({'DOWN', _Ref, process, Pid, Reason}, S)
  when (Reason =:= normal) or (Reason =:= shutdown) ->
    % The peer shut down normally. Hence we just remove him and start up
    %  other peers. Eventually the tracker will re-add him to the peer list
    Peer = etorrent_peer:select(Pid),
    case {Peer#peer.remote_i_state, Peer#peer.local_c_state} of
	{interested, choked} ->
	    rechoke(S);
	_ ->
	    ok
    end,
    etorrent_peer:delete(Pid),
    NewChain = lists:delete(Pid, S#state.opt_unchoke_chain),
    {ok, NS} = start_new_peers([], S#state { num_peers = S#state.num_peers -1,
					     opt_unchoke_chain = NewChain }),
    {noreply, NS};
handle_info({'DOWN', _Ref, process, Pid, _Reason}, S) ->
    % The peer shut down unexpectedly re-add him to the queue in the *back*
    Peer = etorrent_peer:select(Pid),
    {IP, Port} = {Peer#peer.ip, Peer#peer.port},
    case {Peer#peer.remote_i_state, Peer#peer.local_c_state} of
	{interested, choked} ->
	    rechoke(S);
	_ ->
	    ok
    end,
    etorrent_peer:delete(Pid),
    NewChain = lists:delete(Pid, S#state.opt_unchoke_chain),
    {noreply, S#state{available_peers = (S#state.available_peers ++ [{IP, Port}]),
		      num_peers = S#state.num_peers -1,
		      opt_unchoke_chain = NewChain}};
handle_info(Info, State) ->
    error_logger:error_report([unknown_info_peer_group, Info]),
    {noreply, State}.

terminate(_Reason, S) ->
    etorrent_peer:delete(S#state.torrent_id),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

start_new_incoming_peer(IP, Port, S) ->
    case ?MAX_PEER_PROCESSES - S#state.num_peers of
	N when N =< 0 ->
	    {reply, already_enough_connections, S};
	N when is_integer(N), N > 0 ->
	    {ok, Pid} = etorrent_t_peer_pool_sup:add_peer(
			  S#state.peer_group_sup,
			  S#state.our_peer_id,
			  S#state.info_hash,
			  S#state.file_system_pid,
			  self(),
			  S#state.torrent_id),
	    erlang:monitor(process, Pid),
	    etorrent_peer:new(IP, Port, S#state.torrent_id, Pid),
	    NewChain = insert_new_peer_into_chain(Pid, S#state.opt_unchoke_chain),
	    rechoke(S),
	    {reply, {ok, Pid},
	     S#state { num_peers = S#state.num_peers+1,
		       opt_unchoke_chain = NewChain}}
    end.

%%
%% Apply F to each Peer Pid
foreach_pid(F, S) ->
    Peers = etorrent_peer:all(S#state.torrent_id),
    lists:foreach(F, Peers),
    ok.

bcast_got_chunk(Chunk, S) ->
    foreach_pid(fun (Peer) ->
			etorrent_t_peer_recv:endgame_got_chunk(Peer#peer.pid, Chunk)
		end,
		S).

broadcast_have_message(Index, S) ->
    foreach_pid(fun (Peer) ->
			etorrent_t_peer_recv:send_have_piece(Peer#peer.pid, Index)
		end,
		S).

start_new_peers(IPList, State) ->
    %% Update the PeerList with the new incoming peers
    PeerList = lists:usort(IPList ++ State#state.available_peers),
    S = State#state { available_peers = PeerList},

    %% Replenish the connected peers.
    fill_peers(?MAX_PEER_PROCESSES - S#state.num_peers, S).

%%% NOTE: fill_peers/2 and spawn_new_peer/5 tail calls each other.
fill_peers(0, S) ->
    {ok, S};
fill_peers(N, S) ->
    case S#state.available_peers of
	[] ->
	    % No peers available, just stop trying to fill peers
	    {ok, S};
	[{IP, Port} | R] ->
	    % Possible peer. Check it.
	    case is_bad_peer(IP, Port, S) of
		true ->
		    fill_peers(N, S#state{available_peers = R});
		false ->
		    spawn_new_peer(IP, Port, N, S#state{available_peers = R})
	    end
    end.

%%--------------------------------------------------------------------
%% Function: spawn_new_peer(IP, Port, N, S) -> {ok, State}
%% Description: Attempt to spawn the peer at IP/Port. N is the number of
%%   peers we still need to spawn and S is the current state. Returns
%%   a new state to be put into the process.
%%--------------------------------------------------------------------
spawn_new_peer(IP, Port, N, S) ->
    case etorrent_peer:connected(IP, Port, S#state.torrent_id) of
	true ->
	    fill_peers(N, S);
	false ->
	    {ok, Pid} = etorrent_t_peer_pool_sup:add_peer(
			  S#state.peer_group_sup,
			  S#state.our_peer_id,
			  S#state.info_hash,
			  S#state.file_system_pid,
			  self(),
			  S#state.torrent_id),
	    erlang:monitor(process, Pid),
	    etorrent_t_peer_recv:connect(Pid, IP, Port),
	    ok = etorrent_peer:new(IP, Port, S#state.torrent_id, Pid),
	    NewChain = insert_new_peer_into_chain(Pid, S#state.opt_unchoke_chain),
	    rechoke(S),
	    fill_peers(N-1, S#state { num_peers = S#state.num_peers +1,
				      opt_unchoke_chain = NewChain})
    end.

is_bad_peer(IP, Port, S) ->
    etorrent_peer:connected(IP, Port, S#state.torrent_id).



%%--------------------------------------------------------------------
%% Function: rechoke(State) -> ok
%% Description: Recalculate the choke/unchoke state of peers
%%--------------------------------------------------------------------
rechoke(S) ->
    Key = case etorrent_torrent:mode(S#state.torrent_id) of
	      seeding -> #peer.uploaded;
	      leeching -> #peer.downloaded;
	      endgame -> #peer.downloaded
	  end,
    {atomic, Peers} = etorrent_peer:select_fastest(S#state.torrent_id, Key),
    rechoke(Peers, calculate_num_downloaders(S), S).

rechoke(Peers, 0, S) ->
    [optimistic_unchoke_handler(P, S) || P <- Peers],
    ok;
rechoke([], _N, _S) ->
    ok;
rechoke([Peer | Rest], N, S) when is_record(Peer, peer) ->
    case Peer#peer.remote_i_state of
	interested ->
	    etorrent_t_peer_recv:unchoke(Peer#peer.pid),
	    rechoke(Rest, N-1, S);
	not_interested ->
	    etorrent_t_peer_recv:unchoke(Peer#peer.pid),
	    rechoke(Rest, N, S)
    end.

optimistic_unchoke_handler(P, S) ->
    case P#peer.pid =:= S#state.optimistic_unchoke_pid of
	true ->
	    ok; % Handled elsewhere
	false ->
	    etorrent_t_peer_recv:choke(P#peer.pid)
    end.

%% TODO: Make number of downloaders depend on current rate!
calculate_num_downloaders(S) ->
    case etorrent_peer:interested(S#state.optimistic_unchoke_pid) of
	true ->
	    ?DEFAULT_NUM_DOWNLOADERS - 1;
	false ->
	    ?DEFAULT_NUM_DOWNLOADERS
    end.

advance_optimistic_unchoke(S) ->
    NewChain = move_cyclic_chain(S#state.opt_unchoke_chain),
    case NewChain of
	[] ->
	    S; %% No peers yet
	[H | _T] ->
	    etorrent_peer:statechange(S#state.optimistic_unchoke_pid,
				      remove_optimistic_unchoke),
	    %% Do not choke here, a later call to rechoke will do it.
	    etorrent_peer:statechange(H, optimistic_unchoke),
	    etorrent_t_peer_recv:unchoke(H),
	    S#state { opt_unchoke_chain = NewChain,
		      optimistic_unchoke_pid = H }
    end.

move_cyclic_chain([]) -> [];
move_cyclic_chain(Chain) ->
    {Front, Back} = lists:splitwith(fun etorrent_peer:local_unchoked/1, Chain),
    %% Advance chain
    Back ++ Front.

insert_new_peer_into_chain(Pid, Chain) ->
    Length = length(Chain),
    Index = lists:max([0, crypto:rand_uniform(0, Length)]),
    {Front, Back} = lists:split(Index, Chain),
    Front ++ [Pid | Back].




