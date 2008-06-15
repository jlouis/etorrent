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

%% API
-export([start_link/6, add_peers/2, broadcast_have/2, new_incoming_peer/3,
	seed/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {available_peers = [],
	        bad_peers = none,
		our_peer_id = none,
		info_hash = none,
	        peer_process_dict = none,

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
		 file_system_pid = FileSystemPid,
		 peer_process_dict = dict:new() }}.

handle_call({new_incoming_peer, IP, Port}, _From, S) ->
    Reply = case is_bad_peer(IP, Port, S) of
		{atomic, true} ->
		    {bad_peer, S};
		{atomic, false} ->
		    start_new_incoming_peer(IP, Port, S)
	    end,
    {reply, Reply, S};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast({add_peers, IPList}, S) ->
    {ok, NS} = update_available_peers(IPList, S),
    {ok, NS2} = start_new_peers(NS),
    {noreply, NS2};
handle_cast({broadcast_have, Index}, S) ->
    broadcast_have_message(Index, S),
    {noreply, S};
handle_cast(seed, S) ->
    {noreply, S#state{mode = seeding}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(round_tick, S) ->
    case S#state.round of
	0 ->
	    {atomic, _} = etorrent_mnesia_operations:peer_statechange_infohash(
			    S#state.info_hash,
			    remove_optimistic_unchoke),
	    {NS, DoNotTouchPids} = perform_choking_unchoking(S),
	    NNS = select_optimistic_unchoker(DoNotTouchPids, NS),
	    {atomic, _} = etorrent_mnesia_operations:reset_round(S#state.info_hash),
	    {noreply, NNS#state{round = 2}};
	N when is_integer(N) ->
	    {NS, _DoNotTouchPids} = perform_choking_unchoking(S),
	    {atomic, _} = etorrent_mnesia_operations:reset_round(S#state.info_hash),
	    {noreply, NS#state{round = NS#state.round - 1}}
    end;
handle_info({'DOWN', _Ref, process, Pid, Reason}, S)
  when (Reason =:= normal) or (Reason =:= shutdown) ->
    % The peer shut down normally. Hence we just remove him and start up
    %  other peers. Eventually the tracker will re-add him to the peer list
    etorrent_mnesia_operations:delete_peer(Pid),
    {ok, NS} = start_new_peers(S),
    {noreply, NS};
handle_info({'DOWN', _Ref, process, Pid, _Reason}, S) ->
    % The peer shut down unexpectedly re-add him to the queue in the *back*
    {IP, Port} = etorrent_mnesia_operations:select_peer_ip_port_by_pid(Pid),
    {noreply, S#state{available_peers =
		      (S#state.available_peers ++ [{IP, Port}])}};
handle_info(Info, State) ->
    io:format("Unknown info: ~p~n", [Info]),
    {noreply, State}.

terminate(_Reason, S) ->
    error_logger:info_report([peer_group_terminating]),
    {atomic, _} = etorrent_mnesia_operations:delete_torrent(S#state.info_hash),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
start_new_incoming_peer(IP, Port, S) ->
    PeersMissing =
	?MAX_PEER_PROCESSES - dict:size(S#state.peer_process_dict),
    case PeersMissing > 0 of
	true ->
	    {ok, Pid} = etorrent_t_peer_pool_sup:add_peer(
			  S#state.peer_group_sup,
			  S#state.our_peer_id,
			  S#state.info_hash,
			  S#state.file_system_pid,
			  self(),
			  S#state.torrent_id),
	    erlang:monitor(process, Pid),
	    etorrent_mnesia_operations:store_peer(IP, Port, S#state.info_hash, Pid),
	    {ok, Pid};
	false ->
	    already_enough_connections
    end.

broadcast_have_message(Index, S) ->
    Pids = dict:fetch_keys(S#state.peer_process_dict),
    lists:foreach(fun(Pid) ->
			  etorrent_t_peer_recv:send_have_piece(Pid, Index)
		  end,
		  Pids),
    ok.

select_optimistic_unchoker(DoNotTouchPids, S) ->
    Size = dict:size(S#state.peer_process_dict),
    List = dict:to_list(S#state.peer_process_dict),
    % Guard such that we don't enter an infinite loop.
    %   There are multiple optimizations possible here...
    case sets:size(DoNotTouchPids) >= Size of
	true ->
	    S;
	false ->
	    select_optimistic_unchoker(Size, List, DoNotTouchPids, S)
    end.

select_optimistic_unchoker(Size, List, DoNotTouchPids, S) ->
    N = crypto:rand_uniform(1, Size+1),
    {Pid, _PI} = lists:nth(N, List),
    case sets:is_element(Pid, DoNotTouchPids) of
	true ->
	    select_optimistic_unchoker(Size, List, DoNotTouchPids, S);
	false ->
	    {atomic, _} =
		etorrent_mnesia_operations:peer_statechange(Pid, {optimistic_unchoke, true}),
	    etorrent_t_peer_recv:unchoke(Pid),
	    S
    end.


%%--------------------------------------------------------------------
%% Function: perform_choking_unchoking(state()) -> state()
%% Description: Peform choking and unchoking of peers according to the
%%   specification.
%%--------------------------------------------------------------------
perform_choking_unchoking(S) ->
    {atomic, {Interested, NotInterested}} =
	etorrent_mnesia_operations:select_interested_peers(S#state.info_hash),
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
      fun ({_K1, DL1, _UL1}, {_K2, DL2, _UL2}) ->
	      DL1 > DL2
      end,
      Peers).

sort_fastest_uploaders(Peers) ->
    lists:sort(
      fun ({_K1, _DL1, UL1}, {_K2, _DL2, UL2}) ->
	      UL1 > UL2
      end,
      Peers).

find_fastest(N, Interested, F) ->
    List = F(Interested),
    SplitPoint = lists:min([length(List), N]),
    {Downloaders, Rest} = lists:split(SplitPoint, List),
    {Downloaders, Rest}.

find_fastest_peers(N, Interested, S) when S#state.mode == leeching ->
    find_fastest(N, Interested, fun sort_fastest_downloaders/1);
find_fastest_peers(N, Interested, S) when S#state.mode == seeding ->
    find_fastest(N, Interested, fun sort_fastest_uploaders/1).

unchoke_peers(Pids) ->
    lists:foreach(fun({Pid, _DL, _UL}) ->
			  etorrent_t_peer_recv:unchoke(Pid)
		  end, Pids),
    ok.

choke_peers(Pids) ->
    lists:foreach(fun({Pid, _DL, _UL}) ->
			  etorrent_t_peer_recv:choke(Pid)
		  end, Pids),
    ok.

update_available_peers(IPList, S) ->
    NewList = lists:usort(IPList ++ S#state.available_peers),
    {ok, S#state{ available_peers = NewList}}.

start_new_peers(S) ->
    PeersMissing = ?MAX_PEER_PROCESSES - dict:size(S#state.peer_process_dict),
    case PeersMissing > 0 of
	true ->
	    fill_peers(PeersMissing, S);
	false ->
	    {ok, S}
    end.

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
		{atomic, true} ->
		    fill_peers(N, S#state{available_peers = R});
		{atomic, false} ->
		    spawn_new_peer(IP, Port, N, S#state{available_peers = R})
	    end
    end.

spawn_new_peer(IP, Port, N, S) ->
    case etorrent_mnesia_operations:is_peer_connected(IP,
						      Port,
						      S#state.info_hash) of
	{atomic, true} ->
	    fill_peers(N, S);
	{atomic, false} ->
	    {ok, Pid} = etorrent_t_peer_pool_sup:add_peer(
			  S#state.peer_group_sup,
			  S#state.our_peer_id,
			  S#state.info_hash,
			  S#state.file_system_pid,
			  self(),
			  S#state.torrent_id),
	    %% XXX: We set a monitor which we do not use!
	    _Ref = erlang:monitor(process, Pid),
	    etorrent_t_peer_recv:connect(Pid, IP, Port),
	    {atomic, _} =
		etorrent_mnesia_operations:store_peer(IP, Port, S#state.info_hash, Pid),
	    fill_peers(N-1, S)
    end.

%% XXX: This is definitely wrong. But it is as the code is currently
%%   implemented.
is_bad_peer(IP, Port, S) ->
    etorrent_mnesia_operations:is_peer_connected(IP, Port, S#state.info_hash).


