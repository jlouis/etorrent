%%%-------------------------------------------------------------------
%%% File    : etorrent_counters.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Various global counters in etorrent
%%%
%%% Created : 29 Jul 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------
-module(etorrent_counters).

-behaviour(gen_server).

%% API
-export([start_link/0, next/1, obtain_peer_slot/0, release_peer_slot/0,
         max_peer_processes/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {}).
-define(SERVER, ?MODULE).
-define(DEFAULT_MAX_PEER_PROCESSES, 40).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

next(Sequence) ->
    gen_server:call(?SERVER, {next, Sequence}).

obtain_peer_slot() ->
    gen_server:call(?SERVER, obtain_peer_slot).

release_peer_slot() ->
    gen_server:cast(?SERVER, release_peer_slot).

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
    process_flag(trap_exit, true),
    _Tid = ets:new(etorrent_counters, [named_table, protected]),
    ets:insert(etorrent_counters, [{torrent, 0},
                                   {path_map, 0},
                                   {peer_slots, 0}]),
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
handle_call({next, Seq}, _From, S) ->
    N = ets:update_counter(etorrent_counters, Seq, 1),
    {reply, N, S};
handle_call(obtain_peer_slot, _From, S) ->
    [{peer_slots, K}] = ets:lookup(etorrent_counters, peer_slots),
    case K >= max_peer_processes() of
        true ->
            {reply, full, S};
        false ->
            ets:update_counter(etorrent_counters, peer_slots, 1),
            {reply, ok, S}
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
handle_cast(release_peer_slot, S) ->
    K = ets:update_counter(etorrent_counters, peer_slots, -1),
    true = K >= 0,
    {noreply, S};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
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
    true = ets:delete(etorrent_counters),
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
max_peer_processes() ->
    case application:get_env(etorrent, max_peers) of
        {ok, N} when is_integer(N) ->
            N;
        undefined ->
	    ?DEFAULT_MAX_PEER_PROCESSES
    end.
