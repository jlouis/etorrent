%%%-------------------------------------------------------------------
%%% File    : torrent_peer_master.erl
%%% Author  : Jesper Louis Andersen <>
%%% License : See COPYING
%%% Description : Master process for a number of peers.
%%%
%%% Created : 18 Jul 2007 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(torrent_peer_master).

-behaviour(gen_server).

%% API
-export([start_link/4, add_peers/2, uploaded_data/2, downloaded_data/2,
	peer_interested/1, peer_not_interested/1, peer_choked/1,
	peer_unchoked/1, got_piece_from_peer/2, new_incoming_peer]).

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

	        state_pid = none,
	        file_system_pid = none}).

-record(peer_info, {uploaded = 0,
		    downloaded = 0,
		    interested = false,
		    remote_choking = true,

		    optimistic_unchoke = false,
		    ip = none,
		    port = 0,
		    peer_id = none}).

-define(MAX_PEER_PROCESSES, 40).
-define(ROUND_TIME, 10000).
-define(DEFAULT_NUM_DOWNLOADERS, 4).

%%====================================================================
%% API
%%====================================================================
start_link(OurPeerId, InfoHash, StatePid, FileSystemPid) ->
    gen_server:start_link(?MODULE, [OurPeerId, InfoHash,
				    StatePid, FileSystemPid], []).

add_peers(Pid, IPList) ->
    gen_server:cast(Pid, {add_peers, IPList}).

uploaded_data(Pid, Amount) ->
    gen_server:call(Pid, {uploaded_data, Amount}).

downloaded_data(Pid, Amount) ->
    gen_server:call(Pid, {downloaded_data, Amount}).

peer_interested(Pid) ->
    gen_server:call(Pid, interested).

peer_not_interested(Pid) ->
    gen_server:call(Pid, not_interested).

peer_choked(Pid) ->
    gen_server:call(Pid, choked).

peer_unchoked(Pid) ->
    gen_server:call(Pid, unchoked).

got_piece_from_peer(Pid, Index) ->
    gen_server:cast(Pid, {got_piece_from_peer, Index}).

new_incoming_peer(Pid, ReservedBytes, PeerId) ->
    gen_server:call(Pid, {new_incoming_peer, ReservedBytes, PeerId}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([OurPeerId, InfoHash, StatePid, FileSystemPid]) ->
    process_flag(trap_exit, true), % Needed for torrent peers
    {ok, Tref} = timer:send_interval(?ROUND_TIME, self(), round_tick),
    ok = info_hash_map:store_hash(InfoHash),
    {ok, #state{ our_peer_id = OurPeerId,
		 bad_peers = dict:new(),
		 info_hash = InfoHash,
		 state_pid = StatePid,
		 timer_ref = Tref,
		 file_system_pid = FileSystemPid,
		 peer_process_dict = dict:new() }}.

handle_call(choked, {Pid, _Tag}, S) ->
    {reply, ok, peer_dict_update(
		  Pid,
		  fun(PI) ->
			  PI#peer_info{
			    remote_choking = true}
		  end,
		  S)};
handle_call(unchoked, {Pid, _Tag}, S) ->
    {reply, ok, peer_dict_update(
		  Pid,
		  fun(PI) ->
			  PI#peer_info{
			    remote_choking = false}
		  end,
		  S)};
handle_call({uploaded_data, Amount}, {Pid, _Tag}, S) ->
    {reply, ok, peer_dict_update(
		  Pid,
		  fun(PI) ->
			  PI#peer_info{
			    uploaded = PI#peer_info.uploaded + Amount}
		  end,
		  S)};
handle_call({downloaded_data, Amount}, {Pid, _Tag}, S) ->
    {reply, ok, peer_dict_update(
		  Pid,
		  fun(PI) ->
			  PI#peer_info{
			    downloaded = PI#peer_info.downloaded + Amount}
		  end,
		  S)};
handle_call(interested, {Pid, _Tag}, S) ->
    {reply, ok, peer_dict_update(
		  Pid,
		  fun(PI) ->
			  PI#peer_info{interested = true}
		  end,
		  S)};
handle_call(not_interested, {Pid, _Tag}, S) ->
    {reply, ok, peer_dict_update(
		  Pid,
		  fun(PI) ->
			  PI#peer_info{interested = false}
		  end,
		  S)};
handle_call({new_incoming_peer, ReservedBytes, PeerId}, _From, S) ->
    case is_bad_peer(PeerId, S) of
	true ->
	    {reply, bad_peer, S};
	false ->
	    % TODO: Rewrite this to return a Pid from the started server!
	    {reply, bad_peer, S}
    end;
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast({add_peers, IPList}, S) ->
    {ok, NS} = usort_peers(IPList, S),
    io:format("Possible peers: ~p~n", [NS#state.available_peers]),
    {ok, NS2} = start_new_peers(NS),
    {noreply, NS2};
handle_cast({got_piece_from_peer, Index}, S) ->
    broadcast_have_message(Index, S),
    {noreply, S};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(round_tick, S) ->
    error_logger:info_report([timer_ticked]),
    case S#state.round of
	0 ->
	    error_logger:info_report([optimistic_unchoke_change]),
	    {NS, DoNotTouchPids} = perform_choking_unchoking(
				     remove_optimistic_unchoking(S)),
	    NNS = select_optimistic_unchoker(DoNotTouchPids, NS),
	    {noreply, reset_round(NNS#state{round = 2})};
	N when is_integer(N) ->
	    {NS, _DoNotTouchPids} = perform_choking_unchoking(S),
	    {noreply, reset_round(NS#state{round = NS#state.round - 1})}
    end;
handle_info({'EXIT', Pid, Reason}, S) ->
    % Pid has exited for some reason, handle it accordingly
    case Reason of
	normal ->
	    D = dict:erase(Pid, S#state.peer_process_dict),
	    {ok, NS} = start_new_peers(S#state{peer_process_dict = D}),
	    {noreply, NS};
	shutdown ->
	    {stop, shutdown, S};
	R ->
	    PI = dict:fetch(Pid, S#state.peer_process_dict),
	    D  = dict:erase(Pid, S#state.peer_process_dict),
	    Bad = dict:update(PI#peer_info.peer_id, fun(L) -> [R | L] end,
			      [R], S#state.bad_peers),
	    {ok, NS} = start_new_peers(S#state{peer_process_dict = D,
					       bad_peers = Bad}),
	    {noreply, NS}
    end;
handle_info(Info, State) ->
    io:format("Unknown info: ~p~n", [Info]),
    {noreply, State}.

terminate(_Reason, S) ->
    info_hash_map:remove_hash(S#state.info_hash),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

broadcast_have_message(Index, S) ->
    Pids = dict:fetch_keys(S#state.peer_process_dict),
    lists:foreach(fun(Pid) ->
			  torrent_peer:send_have_piece(Pid, Index)
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
	    NS = peer_dict_update(Pid,
				  fun(_K, PI) ->
					  PI#peer_info{optimistic_unchoke =
						       true}
				  end,
				  S),
	    torrent_peer:unchoke(Pid),
	    NS
    end.


%%--------------------------------------------------------------------
%% Function: perform_choking_unchoking(state()) -> state()
%% Description: Peform choking and unchoking of peers according to the
%%   specification.
%%--------------------------------------------------------------------
perform_choking_unchoking(S) ->
    NotInterested = find_not_interested_peers(S#state.peer_process_dict),
    Interested    = find_interested_peers(S#state.peer_process_dict),

    % N fastest interesteds should be kept
    {Downloaders, Rest} =
	find_fastest_downloaders(?DEFAULT_NUM_DOWNLOADERS,
			   Interested),
    unchoke_peers(Downloaders),

    % All peers not interested should be unchoked
    unchoke_peers(dict:fetch_keys(NotInterested)),

    % Choke everyone else
    choke_peers(Rest),

    DoNotTouchPids = sets:from_list(lists:map(fun({K, _V}) -> K end,
					     Downloaders)),
    {S, DoNotTouchPids}.

remove_optimistic_unchoking(S) ->
    peer_dict_map(fun(_K, PI) ->
			  PI#peer_info{optimistic_unchoke = false}
		  end,
		  S).

find_fastest_downloaders(N, Interested) ->
    List = lists:sort(
	     fun ({_K1, PI1}, {_K2, PI2}) ->
		     PI1#peer_info.downloaded > PI2#peer_info.downloaded
	     end,
	     dict:to_list(Interested)),
    PidList = lists:map(fun({K, _V}) -> K end, List),
    SplitPoint = lists:min([length(PidList), N]),
    {Downloaders, Rest} = lists:split(SplitPoint, PidList),
    {Downloaders, Rest}.

unchoke_peers(Pids) ->
    lists:foreach(fun(P) -> torrent_peer:unchoke(P) end, Pids),
    ok.

choke_peers(Pids) ->
    lists:foreach(fun(P) -> torrent_peer:choke(P) end, Pids),
    ok.

find_interested_peers(Dict) ->
    dict:filter(fun(_K, PI) -> PI#peer_info.interested end,
		Dict).

find_not_interested_peers(Dict) ->
    dict:filter(fun(_K, PI) -> not(PI#peer_info.interested) end,
		Dict).


%%--------------------------------------------------------------------
%% Function: peer_dict_update(pid, fun(), state()) -> state()
%% Description: Run fun as an updater on the pid entry in the peer
%%   process dict.
%%--------------------------------------------------------------------
peer_dict_update(Pid, F, S) ->
    D = dict:update(Pid, F, S#state.peer_process_dict),
    S#state{peer_process_dict = D}.

peer_dict_map(F, S) ->
    D = dict:map(F, S#state.peer_process_dict),
    S#state{peer_process_dict = D}.

usort_peers(IPList, S) ->
    NewList = lists:usort(IPList ++ S#state.available_peers),
    {ok, S#state{ available_peers = NewList}}.

start_new_peers(S) ->
    PeersMissing =
	?MAX_PEER_PROCESSES - dict:size(S#state.peer_process_dict),
    if
	PeersMissing > 0 ->
	    fill_peers(PeersMissing, S);
	true ->
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
	[{IP, Port, PeerId} | R] ->
	    % P is a possible peer. Check it.
	    case is_bad_peer_or_ourselves(PeerId, S) of
		true ->
		    fill_peers(N, S#state{available_peers = R});
		false ->
		    spawn_new_peer(IP, Port, PeerId,
				   N,
				   S#state{available_peers = R})
	    end
    end.

spawn_new_peer(IP, Port, PeerId, N, S) ->
    case find_peer_id_in_process_list(PeerId, S) of
	true ->
	    fill_peers(N, S);
	false ->
	    {ok, Pid} = torrent_peer:start_link(IP, Port,
						PeerId,
						S#state.info_hash,
					        S#state.state_pid,
					        S#state.file_system_pid,
					        self()),
	    %sys:trace(Pid, true),
	    torrent_peer:connect(Pid, S#state.our_peer_id),
	    % TODO: Remove this hack:
	    torrent_peer:unchoke(Pid),
	    PI = #peer_info{ip = IP, port = Port, peer_id = PeerId},
	    D = dict:store(Pid, PI, S#state.peer_process_dict),
	    fill_peers(N-1, S#state{ peer_process_dict = D})
    end.

is_bad_peer_or_ourselves(PeerId, S) ->
    is_ourselves(PeerId, S) or is_bad_peer(PeerId, S).

is_ourselves(PeerId, S) ->
    string:equal(PeerId, S#state.our_peer_id).

is_bad_peer(PeerId, S) ->
    case dict:find(PeerId, S#state.bad_peers) of
	{ok, [_E]} ->
	    false;
	{ok, _X} ->
	    true;
	error ->
	    false
    end.

find_peer_id_in_process_list(PeerId, S) ->
    dict:fold(fun(_K, {_IP, _Port, Needle}, AccIn) ->
		      case Needle == PeerId of
			  true ->
			      true;
			  false ->
			      AccIn
		      end
	      end,
	      false,
	      S#state.peer_process_dict).

%%--------------------------------------------------------------------
%% Function: reset_round(state()) -> state()
%% Description: Reset the amount of data uploaded and downloaded.
%%--------------------------------------------------------------------
reset_round(S) ->
    D = dict:map(fun(_Pid, PI) ->
			 PI#peer_info{uploaded = 0,
				      downloaded = 0}
		 end,
		 S#state.peer_process_dict),
    S#state{peer_process_dict = D}.
