%%%-------------------------------------------------------------------
%%% File    : info_hash_map.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% Description : Global mapping of infohashes to peer groups and a mapping
%%%   of peers we are connected to.
%%%
%%% Created : 31 Jul 2007 by Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_t_mapper).

-behaviour(gen_server).

-include("etorrent_mnesia_table.hrl").

%% API
-export([start_link/0, store_hash/1, remove_hash/1, lookup/1,
	 store_peer/4, remove_peer/1, is_connected_peer/3,
	 is_connected_peer_bad/3, set_hash_state/2,
	 choked/1, unchoked/1, uploaded_data/2, downloaded_data/2,
	 interested/1, not_interested/1,
	 set_optimistic_unchoke/2,
	 remove_optimistic_unchoking/1,
	 interest_split/1,
	 reset_round/1,
	 find_ip_port/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, { peer_map = none}).

-record(peer_info, {uploaded = 0,
		    downloaded = 0,
		    interested = false,
		    remote_choking = true,

		    optimistic_unchoke = false}).

-define(SERVER, ?MODULE).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

store_hash(InfoHash) ->
    gen_server:call(?SERVER, {store_hash, InfoHash}).

remove_hash(InfoHash) ->
    gen_server:call(?SERVER, {remove_hash, InfoHash}).

set_hash_state(InfoHash, State) ->
    gen_server:call(?SERVER, {set_hash_state, InfoHash, State}).

store_peer(IP, Port, InfoHash, Pid) ->
    gen_server:call(?SERVER, {store_peer, IP, Port, InfoHash, Pid}).

remove_peer(Pid) ->
    gen_server:call(?SERVER, {remove_peer, Pid}).

is_connected_peer(IP, Port, InfoHash) ->
    gen_server:call(?SERVER, {is_connected_peer, IP, Port, InfoHash}).

is_connected_peer_bad(IP, Port, InfoHash) ->
    gen_server:call(?SERVER, {is_connected_peer, IP, Port, InfoHash}).

choked(Pid) ->
    gen_server:call(?SERVER, {modify_peer, Pid,
			      fun(PI) ->
				      PI#peer_info{remote_choking = true}
			      end}).

unchoked(Pid) ->
    gen_server:call(?SERVER, {modify_peer, Pid,
			      fun(PI) ->
				      PI#peer_info{remote_choking = false}
			      end}).

uploaded_data(Pid, Amount) ->
    gen_server:call(?SERVER,
		    {modify_peer, Pid,
		     fun(PI) ->
			     PI#peer_info{
			       uploaded = PI#peer_info.uploaded + Amount}
		     end}).

downloaded_data(Pid, Amount) ->
    gen_server:call(?SERVER,
		    {modify_peer, Pid,
		     fun(PI) ->
			     PI#peer_info{
			       downloaded = PI#peer_info.downloaded + Amount}
		     end}).

interested(Pid) ->
    gen_server:call(?SERVER,
		    {modify_peer, Pid,
		     fun(PI) ->
			     PI#peer_info{interested = true}
		     end}).

not_interested(Pid) ->
    gen_server:call(?SERVER,
		    {modify_peer, Pid,
		     fun(PI) ->
			     PI#peer_info{interested = false}
		     end}).

set_optimistic_unchoke(Pid, Val) ->
    gen_server:call(?SERVER,
		    {modify_peer, Pid,
		     fun(PI) ->
			     PI#peer_info{optimistic_unchoke = Val}
		     end}).

remove_optimistic_unchoking(InfoHash) ->
    gen_server:call(?SERVER,
		    {remove_optistic_unchoking, InfoHash}).

interest_split(InfoHash) ->
    gen_server:call(?SERVER,
		    {interest_split, InfoHash}).

reset_round(InfoHash) ->
    gen_server:call(?SERVER,
		    {reset_round, InfoHash}).

find_ip_port(Pid) ->
    gen_server:call(?SERVER,
		    {find_ip_port, Pid}).

lookup(InfoHash) ->
    gen_server:call(?SERVER, {lookup, InfoHash}).

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
init([]) ->
    {ok, #state{peer_map      = ets:new(peer_map, [named_table])}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({find_ip_port, _Pid}, _From, S) ->
%%     Selector = ets:fun2ms(fun({P, IPPort, InfoHash, PI}) when P =:= Pid ->
%% 				  IPPort
%% 			  end),
    [IPPort] = ets:select(S#state.peer_map, foo),
    {reply, {ok, IPPort}, S};
handle_call({store_peer, IP, Port, InfoHash, Pid}, _From, S) ->
    ets:insert(S#state.peer_map, {Pid, {IP, Port}, InfoHash, #peer_info{}}),
    {reply, ok, S};
handle_call({remove_peer, Pid}, _From, S) ->
    ets:match_delete(S#state.peer_map, {Pid, '_', '_', '_'}),
    {reply, ok, S};
handle_call({interest_split, InfoHash}, _From, S) ->
    {Intersted, NotInterested} = find_interested_peers(S, InfoHash),
    {reply, {Intersted, NotInterested}, S};
handle_call({modify_peer, Pid, F}, _From, S) ->
    [[IPPort, InfoHash, PI]] = ets:match(S#state.peer_map,
					      {Pid, '$1', '$2', '$3'}),
    ets:insert(S#state.peer_map, {Pid, IPPort, InfoHash, F(PI)}),
    {reply, ok, S};
handle_call({reset_round, InfoHash}, _From, S) ->
    reset_round(InfoHash, S),
    {reply, ok, S};
handle_call({remove_optistic_unchoking, InfoHash}, _From, S) ->
    Matches = ets:match(S#state.peer_map, {'$1', '$2', InfoHash, '$3'}),
    lists:foreach(fun([Pid, IPPort, PI]) ->
			  ets:insert(
			    S#state.peer_map,
			    {Pid, IPPort, InfoHash,
			     PI#peer_info{optimistic_unchoke = false}})
		  end,
		  Matches),
    {reply, ok, S};
handle_call({is_connected_peer, IP, Port, InfoHash}, _From, S) ->
    case ets:match(S#state.peer_map, {'_', {IP, Port}, InfoHash, '_'}) of
	[] ->
	    {reply, false, S};
	X when is_list(X) ->
	    {reply, true, S}
    end;
handle_call({store_hash, InfoHash}, {Pid, _Tag}, S) ->
    Ref = erlang:monitor(process, Pid),
    etorrent_mnesia_operations:store_info_hash(InfoHash, Pid, Ref),
    {reply, ok, S};
handle_call({remove_hash, InfoHash}, {Pid, _Tag}, S) ->
    case etorrent_mnesia_operations:select_info_hash(InfoHash, Pid) of
	[#info_hash { monitor_reference = Ref}] ->
	    erlang:demonitor(Ref),
	    etorrent_mnesia_operations:delete_info_hash(InfoHash),
	    {reply, ok, S};
	_ ->
	    error_logger:error_msg("Pid ~p is not in info_hash_map~n",
				   [Pid]),
	    {reply, ok, S}
    end;
handle_call({set_hash_state, InfoHash, State}, _From, S) ->
    case etorrent_mnesia_operations:set_info_hash_state(InfoHash, State) of
	ok ->
	    {reply, ok, S};
	not_found ->
	    {reply, not_found, S}
    end;
handle_call({lookup, InfoHash}, _From, S) ->
    [#info_hash.storer_pid = Pid] =
	etorrent_mnesia_operations:select_info_hash(InfoHash),
    {reply, {pids, Pid}, S};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({'DOWN', _R, process, Pid, _Reason}, S) ->
    delete_peers(Pid, S),
    etorrent_mnesia_operations:delete_info_hash_by_pid(Pid),
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
find_interested_peers(S, InfoHash) ->
    MS = ets:fun2ms(fun({P, _IP, IH, PI}) when IH == InfoHash ->
			    {P, PI}
		    end),
    Matches = ets:select(S#state.peer_map, MS),
    lists:foldl(fun({P, PI}, {Interested, NotInterested}) ->
			case PI#peer_info.interested of
			    true ->
				{[{P,
				   PI#peer_info.downloaded,
				   PI#peer_info.uploaded} | Interested],
				 NotInterested};
			    false ->
				{Interested,
				 [{P,
				   PI#peer_info.downloaded,
				   PI#peer_info.uploaded} | NotInterested]}
			end
		end,
		{[], []},
		Matches).

%%--------------------------------------------------------------------
%% Function: reset_round(state(), InfoHash) -> ()
%% Description: Reset the amount of uploaded and downloaded data
%%--------------------------------------------------------------------
reset_round(InfoHash, S) ->
    Matches = ets:match(S#state.peer_map, {'$1', '$2', InfoHash, '$3'}),
    lists:foreach(fun([Pid, IPPort, PI]) ->
			  ets:insert(S#state.peer_map,
				     {Pid, IPPort, InfoHash,
				      PI#peer_info{uploaded = 0,
						   downloaded = 0}})
		  end,
		  Matches).

delete_peers(_Pid, S) ->
    %%[[InfoHash]] = ets:match(S#state.info_hash_map, {'$1', Pid}),
    %% TODO: Fix this function
    InfoHash = ok,
    ets:match_delete(S#state.peer_map, {'_', '_', InfoHash, '_'}),
    ok.

