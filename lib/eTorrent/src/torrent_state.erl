%%%-------------------------------------------------------------------
%%% File    : torrent_state.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Track the state of a torrent.
%%%
%%% Created : 14 Jul 2007 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(torrent_state).

-behaviour(gen_server).

%% API
-export([start_link/2, report_to_tracker/1, report_from_tracker/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {uploaded = 0,
		downloaded = 0,
		seeders = 0,
		leechers = 0,
		left = 0,
		port = none}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(Port, TotalSizeLeft) ->
    gen_server:start_link(?MODULE, [Port, TotalSizeLeft], []).

report_to_tracker(Pid) ->
    gen_server:call(Pid, report_to_tracker).

report_from_tracker(Pid, Complete, Incomplete) ->
    gen_server:call(Pid,
		    {report_from_tracker, Complete, Incomplete}).

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
init([Port, TotalSizeLeft]) ->
    {ok, #state{port = Port,
	        left = TotalSizeLeft}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({got_piece, Amount}, _From, S) ->
    {reply, ok, S#state { left = S#state.left - Amount }};
handle_call({downloaded_data, Amount}, _From, S) ->
    {reply, ok, S#state { downloaded = S#state.downloaded + Amount }};
handle_call({uploaded_data, Amount}, _From, S) ->
    {reply, ok, S#state { uploaded = S#state.uploaded + Amount }};
handle_call(report_to_tracker, _From, S) ->
    {reply, {ok,
	     S#state.uploaded,
	     S#state.downloaded,
	     S#state.left,
	     S#state.port}, S};
handle_call({report_from_tracker, Complete, Incomplete},
	    _From, S) ->
    {reply, ok, S#state { seeders = Complete, leechers = Incomplete }}.


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
