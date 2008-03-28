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
	 is_connected_peer_bad/3, set_hash_state/2,
	 choked/1, unchoked/1, uploaded_data/2, downloaded_data/2,
	 interested/1, not_interested/1,
	 set_optimistic_unchoke/2,
	 interest_split/1,
	 find_ip_port/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {}).

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

interest_split(InfoHash) ->
    gen_server:call(?SERVER,
		    {interest_split, InfoHash}).

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
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({find_ip_port, Pid}, _From, S) ->
    [IPPort] = etorrent_mnesia_operations:select_peer_ip_port_by_pid(Pid),
    {reply, {ok, IPPort}, S};
handle_call({interest_split, InfoHash}, _From, S) ->
    {Intersted, NotInterested} = find_interested_peers(InfoHash),
    {reply, {Intersted, NotInterested}, S};
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
find_interested_peers(InfoHash) ->
    etorrent_mnesia_operations:select_interested_peers(InfoHash).

delete_peers(Pid, _S) ->
    etorrent_mnesia_operations:delete_peers(Pid).
