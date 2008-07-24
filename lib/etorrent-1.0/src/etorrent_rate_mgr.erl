%%%-------------------------------------------------------------------
%%% File    : etorrent_rate_mgr.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Rate management process
%%%
%%% Created : 17 Jul 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------
-module(etorrent_rate_mgr).

-include("peer_state.hrl").
-include("rate_mgr.hrl").
-include("etorrent_rate.hrl").

-behaviour(gen_server).

-define(DEFAULT_SNUB_TIME, 30).

%% API
-export([start_link/0,

	 choke/2, unchoke/2, interested/2, not_interested/2,
	 local_choke/2, local_unchoke/2,

	 recv_rate/5, recv_rate/4, send_rate/4,

	 snubbed/2,

	 fetch_recv_rate/2,
	 fetch_send_rate/2,
	 select_state/2,

	 global_rate/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, { recv,
		 send,
		 state,

		 global_recv,
		 global_send}).

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

%% Send state information
choke(Id, Pid) -> gen_server:cast(?SERVER, {choke, Id, Pid}).
unchoke(Id, Pid) -> gen_server:cast(?SERVER, {unchoke, Id, Pid}).
interested(Id, Pid) -> gen_server:cast(?SERVER, {interested, Id, Pid}).
not_interested(Id, Pid) -> gen_server:cast(?SERVER, {not_interested, Id, Pid}).
local_choke(Id, Pid) -> gen_server:cast(?SERVER, {local_choke, Id, Pid}).
local_unchoke(Id, Pid) -> gen_server:cast(?SERVER, {local_unchoke, Id, Pid}).

select_state(Id, Who) ->
    case ets:lookup(etorrent_peer_state, {Id, Who}) of
	[] ->
	    #peer_state { interest_state = not_interested,
			  choke_state = choked,
			  local_choke = true };
	[P] ->
	    P
    end.

snubbed(Id, Who) ->
    T = etorrent_rate:now_secs(),
    case ets:lookup(etorrent_recv_state, {Id, Who}) of
	[] ->
	    false;
	[#rate_mgr { last_got = unknown }] ->
	    false;
	[#rate_mgr { last_got = U}] ->
	    T - U > ?DEFAULT_SNUB_TIME
    end.


fetch_recv_rate(Id, Pid) -> fetch_rate(etorrent_recv_state, Id, Pid).
fetch_send_rate(Id, Pid) -> fetch_rate(etorrent_send_state, Id, Pid).

recv_rate(Id, Pid, Rate, Amount) ->
    recv_rate(Id, Pid, Rate, Amount, normal).

recv_rate(Id, Pid, Rate, Amount, Update) ->
    gen_server:cast(?SERVER, {recv_rate, Id, Pid, Rate, Amount, Update}).

send_rate(Id, Pid, Rate, Amount) ->
    gen_server:cast(?SERVER, {send_rate, Id, Pid, Rate, Amount, normal}).

global_rate() ->
    gen_server:call(?SERVER, global_rate).

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
    RTid = ets:new(etorrent_recv_state, [set, protected, named_table,
					 {keypos, #rate_mgr.pid}]),
    STid = ets:new(etorrent_send_state, [set, protected, named_table,
					 {keypos, #rate_mgr.pid}]),
    StTid = ets:new(etorrent_peer_state, [set, protected, named_table,
					 {keypos, #peer_state.pid}]),
    {ok, #state{ recv = RTid, send = STid, state = StTid,
		 global_recv = etorrent_rate:init(?RATE_FUDGE),
		 global_send = etorrent_rate:init(?RATE_FUDGE)}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(global_rate, _From, S) ->
    #state { global_recv = GR, global_send = GS } = S,
    Reply = { GR#peer_rate.rate, GS#peer_rate.rate },
    {reply, Reply, S};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({What, Id, Pid}, S) ->
    ok = alter_state(What, Id, Pid),
    {noreply, S};
handle_cast({What, Id, Who, Rate, Amount, Update}, S) ->
    NS = alter_state(What, Id, Who, Rate, Amount, Update, S),
    {noreply, NS};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({'DOWN', _Ref, process, Pid, _Reason}, S) ->
    true = ets:match_delete(etorrent_recv_state, #rate_mgr { pid = {'_', Pid}, _='_'}),
    true = ets:match_delete(etorrent_send_state, #rate_mgr { pid = {'_', Pid}, _='_'}),
    true = ets:match_delete(etorrent_peer_state, #peer_state { pid = {'_', Pid}, _='_'}),
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
terminate(_Reason, S) ->
    true = ets:delete(S#state.recv),
    true = ets:delete(S#state.send),
    true = ets:delete(S#state.state),
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

alter_state(What, Id, Pid) ->
    _R = case ets:lookup(etorrent_peer_state, {Id, Pid}) of
	[] ->
	    ets:insert(etorrent_peer_state,
	      alter_record(What,
			   #peer_state { pid = {Id, Pid},
					 choke_state = choked,
					 interest_state = not_interested,
					 local_choke = true})),
	    erlang:monitor(process, Pid);
	[R] ->
	    ets:insert(etorrent_peer_state,
		       alter_record(What, R))
    end,
    ok.

alter_record(What, R) ->
    case What of
	choke ->
	    R#peer_state { choke_state = choked };
	unchoke ->
	    R#peer_state { choke_state = unchoked };
	interested ->
	    R#peer_state { interest_state = interested };
	not_interested ->
	    R#peer_state { interest_state = not_interested };
	local_choke ->
	    R#peer_state { local_choke = true };
	local_unchoke ->
	    R#peer_state { local_choke = false}
    end.

alter_state(What, Id, Who, Rate, Amount, Update, S) ->
    {T, NS} = case What of
		  recv_rate -> NR = etorrent_rate:update(
				      S#state.global_recv,
				      Amount),
			       { etorrent_recv_state,
				 S#state { global_recv = NR }};
		  send_rate -> NR = etorrent_rate:update(
				      S#state.global_send,
				      Amount),
			       { etorrent_send_state,
				 S#state { global_send = NR }}
	      end,
    _R = case ets:lookup(T, {Id, Who}) of
	[] ->
	    ets:insert(T,
	      #rate_mgr { pid = {Id, Who},
			  last_got = case Update of
					 normal -> unknown;
					 last_update -> etorrent_rate:now_secs()
				     end,
			  rate = Rate }),
	    erlang:monitor(process, Who);
	[R] ->
	    ets:insert(T, R#rate_mgr { rate = Rate })
    end,
    NS.

fetch_rate(Where, Id, Pid) ->
    case ets:lookup(Where, {Id, Pid}) of
	[] ->
	    none;
	[R] -> R#rate_mgr.rate
    end.

