%%%-------------------------------------------------------------------
%%% File    : etorrent_bad_peer_mgr.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Bad peer management server
%%%
%%% Created : 19 Jul 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------
-module(etorrent_bad_peer_mgr).

-include("etorrent_bad_peer.hrl").

-behaviour(gen_server).

%% API
-export([start_link/0, is_bad_peer/3, enter_peer/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {}).

-define(SERVER, ?MODULE).
-define(DEFAULT_BAD_COUNT, 2).
-define(GRACE_TIME, 900).
-define(CHECK_TIME, timer:seconds(300)).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

is_bad_peer(IP, Port, TorrentId) ->
    gen_server:call(?SERVER, {is_bad_peer, IP, Port, TorrentId}).

enter_peer(IP, Port) ->
    gen_server:cast(?SERVER, {enter_peer, IP, Port}).

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
    _Tref = timer:send_interval(?CHECK_TIME, self(), cleanup_table),
    _Tid = ets:new(etorrent_bad_peer, [set, protected, named_table,
				       {keypos, #bad_peer.ipport}]),
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
%% A peer is bad if it has offended us or if it is already connected.
handle_call({is_bad_peer, IP, Port, TorrentId}, _From, S) ->
    Reply = case ets:lookup(etorrent_bad_peer, {IP, Port}) of
	[] ->
	    etorrent_peer:connected(IP, Port, TorrentId);
	[P] ->
	    P#bad_peer.offenses > ?DEFAULT_BAD_COUNT
    end,
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
handle_cast({enter_peer, IP, Port}, S) ->
    case ets:lookup(etorrent_bad_peer, {IP, Port}) of
	[] ->
	    ets:insert(etorrent_bad_peer,
		       #bad_peer { ipport = {IP, Port},
				   offenses = 1,
				   last_offense = now() });
	[P] ->
	    ets:insert(etorrent_bad_peer,
		       P#bad_peer { offenses = P#bad_peer.offenses + 1,
				    last_offense = now() })
    end,
    {noreply, S};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(cleanup_table, S) ->
    Bound = etorrent_time:subtract_now_seconds(now(), ?GRACE_TIME),
    true = ets:match_select(etorrent_bad_peer,
			    [{{bad_peer,'_','_','$1'},[{'<','$1',Bound}],[]}]),
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
    ets:delete(etorrent_bad_peer),
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
