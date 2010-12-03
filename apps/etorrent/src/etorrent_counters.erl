%%%-------------------------------------------------------------------
%%% File    : etorrent_counters.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Various global counters in etorrent
%%%
%%% Created : 29 Jul 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------
-module(etorrent_counters).

-behaviour(gen_server).
-include("log.hrl").

%% API
-export([start_link/0, next/1, obtain_peer_slot/0, slots_left/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {}).
-define(SERVER, ?MODULE).

-ignore_xref([{start_link, 0}]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
-spec start_link() -> ignore | {ok, pid()} | {error, any()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Obtain the next integer in the sequence Sequence
-spec next(atom()) -> integer().
next(Sequence) ->
    gen_server:call(?SERVER, {next, Sequence}).

%% @doc Obtain a peer slot to work with.
-spec obtain_peer_slot() -> ok | full.
obtain_peer_slot() ->
    gen_server:call(?SERVER, obtain_peer_slot).

-spec slots_left() -> {value, integer()}.
slots_left() ->
    gen_server:call(?SERVER, slots_left).

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
handle_call(obtain_peer_slot, {Pid, _Tag}, S) ->
    [{peer_slots, K}] = ets:lookup(etorrent_counters, peer_slots),
    case K >= etorrent_config:max_peers() of
        true ->
            {reply, full, S};
        false ->
            _Ref = erlang:monitor(process, Pid),
            _N = ets:update_counter(etorrent_counters, peer_slots, 1),
            {reply, ok, S}
    end;
handle_call(slots_left, _From, S) ->
    [{peer_slots, K}] = ets:lookup(etorrent_counters, peer_slots),
    {reply, {value, etorrent_config:max_peers() - K}, S};
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
handle_info({'DOWN', _Ref, process, _Pid, _Reason}, S) ->
    K = ets:update_counter(etorrent_counters, peer_slots, {2, -1, 0, 0}),
    if
        K >= 0 -> ok;
        true -> ?ERR([counter_negative, K])
    end,
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
