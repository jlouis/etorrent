%%%-------------------------------------------------------------------
%%% File    : etorrent_rate_mgr.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Rate management process
%%%
%%% Created : 17 Jul 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------
-module(etorrent_rate_mgr).

-behaviour(gen_server).

%% API
-export([start_link/0,

	choke/1, unchoke/1, interested/1, not_interested/1,
	recv_rate/2, send_rate/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, { recv,
		 send}).

-record(rate, {pid, % Pid of receiver
	       rate, % Rate
	       choke_state,
	       interest_state }).

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
choke(Pid) -> gen_server:cast(?SERVER, {choke, Pid}).
unchoke(Pid) -> gen_server:cast(?SERVER, {unchoke, Pid}).
interested(Pid) -> gen_server:cast(?SERVER, {interested, Pid}).
not_interested(Pid) -> gen_server:cast(?SERVER, {not_interested, Pid}).

recv_rate(Pid, Rate) ->
    gen_server:cast(?SERVER, {recv_rate, Pid, Rate}).

send_rate(Pid, Rate) ->
    gen_server:cast(?SERVER, {send_rate, Pid, Rate}).

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
    RTid = ets:new(etorrent_recv_state, [set, protected, named_table]),
    STid = ets:new(etorrent_send_state, [set, protected, named_table]),
    {ok, #state{ recv = RTid, send = STid}}.

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
handle_cast({What, Pid}, S) ->
    alter_state(What, Pid),
    {noreply, S};
handle_cast({What, Who, Rate}, S) ->
    alter_state(What, Who, Rate),
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
    true = ets:delete(etorrent_recv_state, Pid),
    true = ets:delete(etorrent_send_state, Pid),
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

alter_state(What, Pid) ->
    case ets:lookup(etorrent_recv_state, Pid) of
	[] ->
	    ets:insert(
	      alter_record(What,
			   #rate { pid = Pid,
				   rate = 0.0,
				   choke_state = choked,
				   interest_state = not_intersted})),
	    erlang:monitor(Pid);
	[R] ->
	    ets:insert(alter_record(What, R))
    end.

alter_record(What, R) ->
    case What of
	choked ->
	    R#rate { choke_state = choked };
	unchoked ->
	    R#rate { choke_state = unchoked };
	interested ->
	    R#rate { interest_state = interested };
	not_interested ->
	    R#rate { interest_state = not_intersted }
    end.

alter_state(What, Who, Rate) ->
    T = case What of
	    recv_rate -> etorrent_recv_state;
	    send_rate -> etorrent_send_state
	end,
    case ets:lookup(T, Who) of
	[] ->
	    ets:insert(
	      #rate { pid = Who,
		      rate = Rate,
		      choke_state = choked,
		      interest_state = not_intersted}),
	    erlang:monitor(Who);
	[R] ->
	    ets:insert(R#rate { rate = Rate })
    end.

