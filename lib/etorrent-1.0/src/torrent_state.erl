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
	 retrieve_bitfield/1, remote_choked/1, remote_unchoked/1,
	 remote_interested/1, remote_not_interested/1,
	 remote_have_piece/2, num_pieces/1, remote_bitfield/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {uploaded = 0,
		downloaded = 0,
		left = 0,

		seeders = 0,
		leechers = 0,

		piece_set = none,
	        num_pieces = 0,

	        histogram = none}).

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

remote_choked(Pid) ->
    gen_server:cast(Pid, {remote_choked, self()}).

remote_unchoked(Pid) ->
    gen_server:cast(Pid, {remote_unchoked, self()}).

remote_interested(Pid) ->
    gen_server:cast(Pid, {remote_interested, self()}).

remote_not_interested(Pid) ->
    gen_server:cast(Pid, {remote_not_interested, self()}).

remote_have_piece(Pid, PieceNum) ->
    gen_server:call(Pid, {remote_have_piece, PieceNum}).

remote_bitfield(Pid, PieceSet) ->
    gen_server:call(Pid, {remote_bitfield, PieceSet}).

remove_bitfield(Pid, PieceSet) ->
    gen_server:call(Pid, {remove_bitfield, PieceSet}).

num_pieces(Pid) ->
    gen_server:call(Pid, num_pieces).

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
    {PieceSet, Size} = convert_diskstate_to_set(DiskState),
    {ok, #state{piece_set = PieceSet,
		num_pieces = Size,
		histogram = histogram:new(),
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
handle_call(num_pieces, _From, S) ->
    {reply, S#state.num_pieces, S};
handle_call(report_to_tracker, _From, S) ->
    {reply, {ok,
	     S#state.uploaded,
	     S#state.downloaded,
	     S#state.left}, S};
handle_call(retrieve_bitfield, _From, S) ->
    BF = peer_communication:construct_bitfield(S#state.num_pieces,
					       S#state.piece_set),
    {reply, BF, S};
handle_call({remote_have_piece, PieceNum}, _From, S) ->
    case piece_valid(PieceNum, S) of
	true ->
	    NS = S#state { histogram = histogram:increase_piece(
					 PieceNum, S#state.histogram) },
	    {reply, ok, NS};
	false ->
	    {reply, invalid_piece, S}
    end;
handle_call({remote_bitfield, PieceSet}, _From, S) ->
    NewH = sets:fold(fun(E, H) ->
			     case piece_valid(E, S) of
				 true ->
				     histogram:increase_piece(E, H);
				 false ->
				     H
			     end
		     end,
		     S#state.histogram,
		     PieceSet),
    {reply, ok, S#state{histogram = NewH}};
handle_call({remove_bitfield, PieceSet}, _From, S) ->
    NewH = sets:fold(fun(E, H) ->
			     case piece_valid(E, S) of
				 true ->
				     histogram:decrease_piece(E, H);
				 false ->
				     H
			     end
		     end,
		     S#state.histogram,
		     PieceSet),
    {reply, ok, S#state{histogram = NewH}};
handle_call({report_from_tracker, Complete, Incomplete},
	    _From, S) ->
    {reply, ok, S#state { seeders = Complete, leechers = Incomplete }}.


%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
% TODO: torrent_state:handle_cast : Handle interested and choke globally!
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

convert_diskstate_to_set(DiskState) ->
    Set = dict:fold(fun (K, {_H, _O, Got}, Acc) ->
			    case Got of
				ok ->
				    sets:add_element(K, Acc);
				not_ok ->
				    Acc
			    end
		    end,
		    sets:new(),
		    DiskState),
    Size = dict:size(DiskState),
    {Set, Size}.

piece_valid(PieceNum, S) ->
    if
	PieceNum =< S#state.num_pieces ->
	    true;
	true ->
	    false
    end.
