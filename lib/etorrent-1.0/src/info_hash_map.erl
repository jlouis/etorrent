%%%-------------------------------------------------------------------
%%% File    : info_hash_map.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% Description : Global mapping of infohashes to Peer Masters
%%%
%%% Created : 31 Jul 2007 by Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(info_hash_map).

-behaviour(gen_server).

%% API
-export([start_link/0, store_hash/1, remove_hash/1, lookup/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, { info_hash_map = none}).
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
    {ok, #state{ info_hash_map = ets:new(infohash_map, [named_table])}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({store_hash, InfoHash}, {Pid, _Tag}, S) ->
    Ref = erlang:monitor(process, Pid),
    ets:insert(S#state.info_hash_map, {InfoHash, Pid, Ref}),
    {reply, ok, S};
handle_call({remove_hash, InfoHash}, {Pid, _Tag}, S) ->
    case ets:match(S#state.info_hash_map, {InfoHash, Pid, '$1'}) of
	[[Ref]] ->
	    erlang:demonitor(Ref),
	    ets:delete(S#state.info_hash_map, {InfoHash, Pid, Ref}),
	    {reply, ok, S};
	_ ->
	    error_logger:warning_report([info_hash_map,
					 handle_call,
					 remove_hash,
					 no_pid_in_ets]),
	    {reply, ok, S}
    end;
handle_call({lookup, InfoHash}, _From, S) ->
    case ets:match(S#state.info_hash_map, {InfoHash, '$1', '_'}) of
	[[Pid]] ->
	    {reply, {ok, Pid}, S};
	[] ->
	    {reply, not_found, S}
    end;
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
    [[InfoHash]] = ets:match(S#state.info_hash_map, {'$1', Pid}),
    ets:delete(S#state.info_hash_map, {InfoHash, Pid}),
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
