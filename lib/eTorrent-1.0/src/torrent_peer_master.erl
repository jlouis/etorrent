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
-export([start_link/0, add_peers/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {available_peers = [],
	        bad_peers = none,
	        peer_process_dict = none}).

-define(MAX_PEER_PROCESSES, 40).

%%====================================================================
%% API
%%====================================================================
start_link() ->
    gen_server:start_link(?MODULE, [], []).

add_peers(Pid, IPList) ->
    gen_server:cast(Pid, {add_peers, IPList}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    process_flag(trap_exit, true), % Needed for torrent peers
    {ok, #state{ bad_peers = dict:new(),
		 peer_process_dict = dict:new() }}.

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

handle_info(_Info, State) ->
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
	    case is_bad_peer(PeerId, S) of
		true ->
		    spawn_new_peer(IP, Port, PeerId,
				   N,
				   S#state{available_peers = R});
		false ->
		    fill_peers(N, S#state{ available_peers = R})
	    end
    end.

spawn_new_peer(IP, Port, PeerId, N, S) ->
    case find_peer_id_in_process_list(PeerId, S) of
	true ->
	    fill_peers(N, S);
	false ->
	    {ok, Pid} = torrent_peer:start_link(IP, Port, PeerId),
	    torrent_peer:connect(Pid),
	    D = dict:store(Pid, {IP, Port, PeerId}, S#state.peer_process_dict),
	    fill_peers(N-1, S#state{ peer_process_dict = D})
    end.

is_bad_peer(PeerId, S) ->
    case dict:find(PeerId, S#state.bad_peers) of
	{ok, [_E]} ->
	    true;
	{ok, _X} ->
	    false;
	error ->
	    true
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


