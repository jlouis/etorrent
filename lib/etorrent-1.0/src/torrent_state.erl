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
-export([start_link/1, report_to_tracker/1, report_from_tracker/3,
	 retrieve_bitfield/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {uploaded = 0,
		downloaded = 0,
		left = 0,

		seeders = 0,
		leechers = 0,

		disk_state = none}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(DiskState) ->
    gen_server:start_link(?MODULE, [DiskState], []).

report_to_tracker(Pid) ->
    gen_server:call(Pid, report_to_tracker).

report_from_tracker(Pid, Complete, Incomplete) ->
    gen_server:call(Pid,
		    {report_from_tracker, Complete, Incomplete}).

retrieve_bitfield(Pid) ->
    gen_server:call(Pid,
		    retrieve_bitfield, 10000).

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
init([DiskState]) ->
    {ok, #state{disk_state = DiskState,
	        left = calculate_amount_left(DiskState)}}.

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
	     S#state.left}, S};
handle_call(retrieve_bitfield, _From, S) ->
    BF = peer_communication:construct_bitfield(S#state.disk_state),
    {reply, BF, S};
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
terminate(Reason, _State) ->
    io:format("Terminating ~p~n", [Reason]),
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
calculate_amount_left(DiskState) ->
    dict:fold(fun (_K, {_Hash, Ops, Ok}, Total) ->
		      case Ok of
			  ok ->
			      Total;
			  not_ok ->
			      Total + size_of_ops(Ops)
		      end
	      end,
	      0,
	      DiskState).

size_of_ops(Ops) ->
    lists:foldl(fun ({_Path, _Offset, Size}, Total) ->
			Size + Total end,
		0,
		Ops).
