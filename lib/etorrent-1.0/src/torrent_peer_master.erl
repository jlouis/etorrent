%%%-------------------------------------------------------------------
%%% File    : torrent_peer_master.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Master process for a number of peers.
%%%
%%% Created : 18 Jul 2007 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(torrent_peer_master).

-behaviour(gen_server).

%% API
-export([start_link/4, add_peers/2, uploaded_data/2, downloaded_data/2,
	peer_interested/1, peer_not_interested/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {available_peers = [],
	        bad_peers = none,
		our_peer_id = none,
		info_hash = none,
	        peer_process_dict = none,

	        state_pid = none,
	        file_system_pid = none}).

-record(peer_info, {uploaded = 0,
		    downloaded = 0,
		    interested = false,
		    choking = true,

		    ip = none,
		    port = 0,
		    peer_id}).

-define(MAX_PEER_PROCESSES, 40).

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

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([OurPeerId, InfoHash, StatePid, FileSystemPid]) ->
    process_flag(trap_exit, true), % Needed for torrent peers
    {ok, #state{ our_peer_id = OurPeerId,
		 bad_peers = dict:new(),
		 info_hash = InfoHash,
		 state_pid = StatePid,
		 file_system_pid = FileSystemPid,
		 peer_process_dict = dict:new() }}.

handle_call({uploaded_data, _Amount}, _From, S) ->
    {reply, ok, S};
handle_call({downloaded_data, _Amount}, _From, S) ->
    {reply, ok, S};
handle_call(interested, _From, S) ->
    {reply, ok, S};
handle_call(not_interested, _From, S) ->
    {reply, ok, S};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast({add_peers, IPList}, S) ->
    {ok, NS} = usort_peers(IPList, S),
    io:format("Possible peers: ~p~n", [NS#state.available_peers]),
    {ok, NS2} = start_new_peers(NS),
    {noreply, NS2};
handle_cast(_Msg, State) ->
    {noreply, State}.

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

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
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
    case string:equal(PeerId, S#state.our_peer_id) of
	true ->
	    true;
	false ->
	    case dict:find(PeerId, S#state.bad_peers) of
		{ok, [_E]} ->
		    false;
		{ok, _X} ->
		    true;
		error ->
		    false
	    end
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
