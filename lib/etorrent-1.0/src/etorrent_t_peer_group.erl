%%%-------------------------------------------------------------------
%%% File    : etorrent_t_peer_group.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% License : See COPYING
%%% Description : Master process for a number of peers.
%%%
%%% Created : 18 Jul 2007 by
%%%      Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------

-module(etorrent_t_peer_group).

-behaviour(gen_server).

-include("etorrent_mnesia_table.hrl").

%% API
-export([start_link/6, add_peers/2, broadcast_have/2, new_incoming_peer/3,
	seed/1, broadcast_got_chunk/2]).

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

	        file_system_pid = none,
		peer_group_sup = none,
		torrent_id = none,

	        mode = leeching}).

-define(MAX_PEER_PROCESSES, 40).
-define(ROUND_TIME, 10000).
-define(DEFAULT_NUM_DOWNLOADERS, 4).

%%====================================================================
%% API
%%====================================================================
start_link(OurPeerId, PeerGroup, InfoHash,
	   FileSystemPid, TorrentState, TorrentHandle) ->
    gen_server:start_link(?MODULE, [OurPeerId, PeerGroup, InfoHash,
				    FileSystemPid, TorrentState, TorrentHandle], []).

add_peers(Pid, IPList) ->
    gen_server:cast(Pid, {add_peers, IPList}).

broadcast_have(Pid, Index) ->
    gen_server:cast(Pid, {broadcast_have, Index}).

broadcast_got_chunk(Pid, Chunk) ->
    gen_server:cast(Pid, {broadcast_got_chunk, Chunk}).

new_incoming_peer(Pid, IP, Port) ->
    gen_server:call(Pid, {new_incoming_peer, IP, Port}).

seed(Pid) ->
    gen_server:cast(Pid, seed).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([OurPeerId, PeerGroup, InfoHash,
      FileSystemPid, TorrentState, TorrentId]) when is_integer(TorrentId) ->
    {ok, Tref} = timer:send_interval(?ROUND_TIME, self(), round_tick),
    {ok, #state{ our_peer_id = OurPeerId,
		 peer_group_sup = PeerGroup,
		 bad_peers = dict:new(),
		 info_hash = InfoHash,
		 timer_ref = Tref,
		 torrent_id = TorrentId,
		 mode = TorrentState,
		 file_system_pid = FileSystemPid}}.

handle_call({new_incoming_peer, IP, Port}, _From, S) ->
    case is_bad_peer(IP, Port, S) of
	{atomic, true} ->
	    {reply, bad_peer, S};
	{atomic, false} ->
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
handle_cast(seed, S) ->
    etorrent_torrent:statechange(S#state.torrent_id, seeding),
    {noreply, S#state{mode = seeding}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(round_tick, S) ->
    case S#state.round of
	0 ->
	    etorrent_peer:statechange(S#state.torrent_id, remove_optimistic_unchoke),
	    {NS, DoNotTouchPids} = perform_choking_unchoking(S),
	    NNS = select_optimistic_unchoker(DoNotTouchPids, NS),
	    {atomic, _} = etorrent_peer:reset_round(S#state.torrent_id),
	    {noreply, NNS#state{round = 2}};
	N when is_integer(N) ->
	    {NS, _DoNotTouchPids} = perform_choking_unchoking(S),
	    {atomic, _} = etorrent_peer:reset_round(S#state.torrent_id),
	    {noreply, NS#state{round = NS#state.round - 1}}
    end;
handle_info({'DOWN', _Ref, process, Pid, Reason}, S)
  when (Reason =:= normal) or (Reason =:= shutdown) ->
    % The peer shut down normally. Hence we just remove him and start up
    %  other peers. Eventually the tracker will re-add him to the peer list
    etorrent_peer:delete (Pid),
    {ok, NS} = start_new_peers([], S#state { num_peers = S#state.num_peers -1}),
    {noreply, NS};
handle_info({'DOWN', _Ref, process, Pid, _Reason}, S) ->
    % The peer shut down unexpectedly re-add him to the queue in the *back*
    {IP, Port} = etorrent_peer:get_ip_port(Pid),
    etorrent_peer:delete(Pid),
    {noreply, S#state{available_peers =
		      (S#state.available_peers ++ [{IP, Port}]),
		      num_peers = S#state.num_peers -1}};
handle_info(Info, State) ->
    error_logger:error_report([unknown_info_peer_group, Info]),
    {noreply, State}.

terminate(_Reason, S) ->
    error_logger:info_report([peer_group_terminating]),
    {atomic, _} = etorrent_torrent:delete(S#state.torrent_id),
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
	    {reply, {ok, Pid},
	     S#state { num_peers = S#state.num_peers+1 }}
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

select_optimistic_unchoker(DoNotTouchPids, S) ->
    Size = S#state.num_peers,
    Peers = etorrent_peer:all(S#state.torrent_id),
    % Guard such that we don't enter an infinite loop.
    %   There are multiple optimizations possible here...
    %% XXX: This code looks infinitely wrong. Plzfx.
    case sets:size(DoNotTouchPids) >= Size of
	true ->
	    S;
	false ->
	    select_optimistic_unchoker(Size, Peers, DoNotTouchPids, S)
    end.

select_optimistic_unchoker(Size, Peers, DoNotTouchPids, S) ->
    N = crypto:rand_uniform(1, Size+1),
    Peer = lists:nth(N, Peers),
    case sets:is_element(Peer#peer.pid, DoNotTouchPids) of
	true ->
	    select_optimistic_unchoker(Size, Peers, DoNotTouchPids, S);
	false ->
	    {atomic, _} =
		etorrent_peer:statechange(Peer, optimistic_unchoke),
	    etorrent_t_peer_recv:unchoke(Peer#peer.pid),
	    S
    end.


%%--------------------------------------------------------------------
%% Function: perform_choking_unchoking(state()) -> state()
%% Description: Peform choking and unchoking of peers according to the
%%   specification.
%%--------------------------------------------------------------------
perform_choking_unchoking(S) ->
    {atomic, {Interested, NotInterested}} =
	etorrent_peer:partition_peers_by_interest(S#state.torrent_id),
    % N fastest interesteds should be kept
    {Downloaders, Rest} =
	find_fastest_peers(?DEFAULT_NUM_DOWNLOADERS,
			   Interested, S),
    unchoke_peers(Downloaders),

    % All peers not interested should be unchoked
    unchoke_peers(NotInterested),

    % Choke everyone else
    choke_peers(Rest),

    DoNotTouchPids = sets:from_list(Downloaders),
    {S, DoNotTouchPids}.

sort_fastest_downloaders(Peers) ->
    lists:sort(
      fun (P1, P2) ->
	      P1#peer.downloaded > P2#peer.downloaded
      end,
      Peers).

sort_fastest_uploaders(Peers) ->
    lists:sort(
      fun (P1, P2) ->
	      P1#peer.uploaded > P2#peer.uploaded
      end,
      Peers).

find_fastest_peers(N, Interested, S) when S#state.mode =:= leeching ->
    etorrent_utils:gsplit(N, sort_fastest_downloaders(Interested));
find_fastest_peers(N, Interested, S) when S#state.mode =:= seeding ->
    etorrent_utils:gsplit(N, sort_fastest_uploaders(Interested)).

unchoke_peers(Peers) ->
    lists:foreach(fun(P) ->
			  etorrent_t_peer_recv:unchoke(P#peer.pid)
		  end, Peers),
    ok.

choke_peers(Peers) ->
    lists:foreach(fun(P) ->
			  etorrent_t_peer_recv:choke(P#peer.pid)
		  end, Peers),
    ok.

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
    case etorrent_peer:is_connected(IP, Port, S#state.torrent_id) of
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
	    fill_peers(N-1, S#state { num_peers = S#state.num_peers +1})
    end.

is_bad_peer(IP, Port, S) ->
    etorrent_peer:is_connected(IP, Port, S#state.torrent_id).


