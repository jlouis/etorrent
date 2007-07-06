%%%-------------------------------------------------------------------
%%% File    : filesystem.erl
%%% Author  : User Jlouis <jlouis@succubus.localdomain>
%%% Description : 
%%%
%%% Created : 30 Jan 2007 by User Jlouis <jlouis@succubus.localdomain>
%%%-------------------------------------------------------------------
-module(filesystem).

-behaviour(gen_server).

%% API
-export([start_link/1, request_piece/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {completed = 0,
		piecelength = none,
		piecemap = none,
		data = none}).


%%====================================================================
%% API
%%====================================================================
start_link(Torrent) ->
    gen_server:start_link(?MODULE, [Torrent], []).

request_piece(Pid, Index, Begin, Len) ->
    %% Retrieve data from the file system for the requested bit.
    gen_server:call(Pid, {request_piece, Index, Begin, Len}).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Torrent]) ->
    PieceMap = build_piecemap(metainfo:get_pieces(Torrent)),
    PieceLength = metainfo:get_piece_length(Torrent),
    Disk = dets:new(disk_data, []),
    {ok, #state{piecemap = PieceMap,
		   piecelength = PieceLength,
		   data = Disk}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(completed_amount, _Who, State) ->
    {reply, State#state.completed, State}.

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
handle_info(Info, State) ->
    error_logger:error_report(Info, State).

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



