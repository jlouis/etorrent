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

-behaviour(gen_server).


%% API
-export([start_link/0,

	choke/2, unchoke/2, interested/2, not_interested/2,
	recv_rate/3, send_rate/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, { recv,
		 send,
		 state}).

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

recv_rate(Id, Pid, Rate) ->
    gen_server:cast(?SERVER, {recv_rate, Id, Pid, Rate}).

send_rate(Id, Pid, Rate) ->
    gen_server:cast(?SERVER, {send_rate, Id, Pid, Rate}).

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
    {ok, #state{ recv = RTid, send = STid, state = StTid}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
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
handle_cast({What, Id, Who, Rate}, S) ->
    ok = alter_state(What, Id, Who, Rate),
    {noreply, S};
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
					 interest_state = not_intersted})),
	    erlang:monitor(process, Pid);
	[R] ->
	    ets:insert(etorrent_peer_state,
		       alter_record(What, R))
    end,
    ok.

alter_record(What, R) ->
    case What of
	choked ->
	    R#peer_state { choke_state = choked };
	unchok ->
	    R#peer_state { choke_state = unchoked };
	interested ->
	    R#peer_state { interest_state = interested };
	not_interested ->
	    R#peer_state { interest_state = not_intersted }
    end.

alter_state(What, Id, Who, Rate) ->
    T = case What of
	    recv_rate -> etorrent_recv_state;
	    send_rate -> etorrent_send_state
	end,
    _R = case ets:lookup(T, {Id, Who}) of
	[] ->
	    ets:insert(T,
	      #rate_mgr { pid = {Id, Who},
			  rate = Rate }),
	    erlang:monitor(process, Who);
	[R] ->
	    ets:insert(T, R#rate_mgr { rate = Rate })
    end,
    ok.

