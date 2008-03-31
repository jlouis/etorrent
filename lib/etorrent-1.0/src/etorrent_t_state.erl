%%%-------------------------------------------------------------------
%%% File    : etorrent_t_state.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% License : See COPYING
%%% Description : Track the state of a torrent.
%%%
%%% Created : 14 Jul 2007 by
%%%     Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_t_state).

-behaviour(gen_server).

%% API
-export([start_link/2, report_to_tracker/1, report_from_tracker/3,
	 retrieve_bitfield/1, remote_have_piece/2, num_pieces/1,
	 remote_bitfield/2, remove_bitfield/2, request_new_piece/2,
	 downloaded_data/2, uploaded_data/2, got_piece_from_peer/3,
	 endgame/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {uploaded = 0,
		downloaded = 0,
		left = 0,

		endgame = false,

		seeders = 0,
		leechers = 0,

		piece_set = none,
		piece_setorrent_missing = none,
		piece_assignment = none,
		piece_size = 0,
	        num_pieces = 0,
		torrent_size = 0,

		control_pid = none,

	        histogram = none}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(PieceSize, ControlPid) ->
    gen_server:start_link(?MODULE, [PieceSize, ControlPid], []).

endgame(Pid) ->
    gen_server:call(Pid, endgame).

report_to_tracker(Pid) ->
    gen_server:call(Pid, report_to_tracker).

report_from_tracker(Pid, Complete, Incomplete) ->
    gen_server:call(Pid,
		    {report_from_tracker, Complete, Incomplete}).

retrieve_bitfield(Pid) ->
    gen_server:call(Pid,  retrieve_bitfield, 10000).

remote_have_piece(Pid, PieceNum) ->
    gen_server:call(Pid, {remote_have_piece, PieceNum}).

remote_bitfield(Pid, PieceSet) ->
    gen_server:call(Pid, {remote_bitfield, PieceSet}).

remove_bitfield(Pid, PieceSet) ->
    gen_server:call(Pid, {remove_bitfield, PieceSet}).

num_pieces(Pid) ->
    gen_server:call(Pid, num_pieces).

request_new_piece(Pid, PeerPieces) ->
    gen_server:call(Pid, {request_new_piece, PeerPieces}).

downloaded_data(Pid, Amount) ->
    gen_server:call(Pid, {downloaded_data, Amount}).

uploaded_data(Pid, Amount) ->
    gen_server:call(Pid, {uploaded_data, Amount}).

got_piece_from_peer(Pid, Pn, DataSize) ->
    gen_server:call(Pid, {got_piece_from_peer, Pn, DataSize}).

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
init([PieceSize, ControlPid]) ->
    {PieceSet, Missing, Size} =
	convert_diskstate_to_set(ControlPid),
    AmountLeft = calculate_amount_left(ControlPid),
    {ok, #state{piece_set = PieceSet,
		piece_setorrent_missing = Missing,
		piece_assignment = dict:new(),
		num_pieces = Size,
		piece_size = PieceSize,
		histogram = etorrent_histogram:new(),
		torrent_size = AmountLeft,
	        left = AmountLeft,
	        control_pid = ControlPid}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({got_piece_from_peer, Pn, DataSize}, {Pid, _Tag}, S) ->
    Assignments = dict:update(Pid, fun(L) -> lists:delete(Pn, L) end,
			      [], S#state.piece_assignment),
    Left = S#state.left - DataSize,
    case Left == 0 of
	true ->
	    etorrent_t_control:seed(S#state.control_pid);
	false ->
	    ok
    end,
    {reply, ok, S#state { left = Left, piece_assignment = Assignments}};
handle_call(endgame, _From, S) ->
    {reply, ok, S#state { endgame = true }};
handle_call({downloaded_data, Amount}, _From, S) ->
    {reply, ok, S#state { downloaded = S#state.downloaded + Amount }};
handle_call({uploaded_data, Amount}, _From, S) ->
    {reply, ok, S#state { uploaded = S#state.uploaded + Amount }};
handle_call(num_pieces, _From, S) ->
    {reply, S#state.num_pieces, S};
handle_call(report_to_tracker, _From, S) ->
    {reply, {{uploaded, S#state.uploaded},
	     {downloaded, S#state.downloaded},
	     {left, S#state.left}}, S};
handle_call(retrieve_bitfield, _From, S) ->
    BF = etorrent_peer_communication:construct_bitfield(S#state.num_pieces,
					       S#state.piece_set),
    {reply, BF, S};
handle_call({remote_have_piece, PieceNum}, _From, S) ->
    case piece_valid(PieceNum, S) of
	true ->
	    NS = S#state { histogram = etorrent_histogram:increase_piece(
					 PieceNum, S#state.histogram) },
	    Reply = case sets:is_element(PieceNum, NS#state.piece_set) of
			true ->
			    not_interested;
			false ->
			    interested
		    end,
	    {reply, Reply, NS};
	false ->
	    {reply, invalid_piece, S}
    end;
handle_call({remote_bitfield, PieceSet}, _From, S) ->
    {NewH, Reply} = sets:fold(
		      fun(E, {H, Interest}) ->
			      case piece_valid(E, S) of
				  true when Interest == not_valid ->
				      {H, not_valid};
				  true when Interest == interested ->
				      {etorrent_histogram:increase_piece(E, H),
				       interested};
				  true when Interest == not_interested ->
				      {etorrent_histogram:increase_piece(E, H),
				       case sets:is_element(
					      E, S#state.piece_set) of
					   true ->
					       not_interested;
					   false ->
					       interested
				       end};
				  false ->
				      {H, not_valid}
			      end
		      end,
		      {S#state.histogram, not_interested},
		      PieceSet),
    case Reply of
	not_valid ->
	    {reply, not_valid, S};
	R ->
	    {reply, R, S#state{histogram = NewH}}
    end;
handle_call({remove_bitfield, PieceSet}, _From, S) ->
    NewH = sets:fold(fun(E, H) ->
			     case piece_valid(E, S) of
				 true ->
				     etorrent_histogram:decrease_piece(E, H);
				 false ->
				     H
			     end
		     end,
		     S#state.histogram,
		     PieceSet),
    {reply, ok, S#state{histogram = NewH}};
handle_call({request_new_piece, _}, _, S) when S#state.endgame =:= true ->
    {reply, endgame, S};
handle_call({request_new_piece, PeerPieces}, {From, _Tag}, S) ->
    EligiblePieces = sets:intersection(PeerPieces, S#state.piece_setorrent_missing),
    case etorrent_utils:sets_is_empty(EligiblePieces) of
	true ->
	    {reply, not_interested, S};
	false ->
	    case etorrent_histogram:find_rarest_piece(EligiblePieces,
						S#state.histogram) of
		PieceNum ->
		    PieceSize = find_piece_size(PieceNum, S),
		    Missing = sets:del_element(PieceNum,
					       S#state.piece_setorrent_missing),
		    erlang:monitor(process, From),
		    Assignments =
			dict:update(From, fun(L) -> [PieceNum | L] end,
				    [PieceNum], S#state.piece_assignment),
		    {reply, {ok, PieceNum, PieceSize},
		     S#state{piece_setorrent_missing = Missing,
			     piece_assignment = Assignments}}
	    end
    end;
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
handle_info({'DOWN', _Ref, process, Pid, _Reason}, S) ->
    case dict:find(Pid, S#state.piece_assignment) of
	{ok, Assignment} ->
	    Missing = lists:foldl(fun(Pn, Missing) ->
					  sets:add_element(Pn, Missing)
				  end,
				  S#state.piece_setorrent_missing,
				  Assignment),
	    Assignments = dict:erase(Pid, S#state.piece_assignment),
	    {noreply, S#state{piece_setorrent_missing = Missing,
			      piece_assignment  = Assignments}};
	error ->
	    {noreply, S}
    end;
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
piece_valid(PieceNum, S) ->
     (PieceNum < S#state.num_pieces) and (PieceNum >= 0).

find_piece_size(PieceNum, S) when PieceNum == (S#state.num_pieces-1) ->
    S#state.torrent_size rem S#state.piece_size;
find_piece_size(PieceNum, S) when PieceNum < (S#state.num_pieces-1) ->
    S#state.piece_size.


size_of_ops(Ops) ->
    lists:foldl(fun ({_Path, _Offset, Size}, Total) ->
			Size + Total end,
		0,
		Ops).

calculate_amount_left(Handle) ->
    Objects = etorrent_mnesia_operations:file_access_torrent_pieces(Handle),
    Sum = lists:foldl(fun([_Pn, Ops, Done], Sum) ->
			      case Done of
				  fetched ->
				      Sum;
				  not_fetched ->
				      Sum + size_of_ops(Ops)
			      end
		      end,
		      0,
		      Objects),
    Sum.

convert_diskstate_to_set(Handle) ->
    Objects = etorrent_mnesia_operations:file_access_torrent_pieces(Handle),
    {Set, MissingSet} =
	lists:foldl(fun([Pn, _Ops, Done], {Set, MissingSet}) ->
			    case Done of
				fetched ->
				    {sets:add_element(Pn, Set),
				     MissingSet};
				not_fetched ->
				    {Set,
				     sets:add_element(Pn, MissingSet)}
			    end
		    end,
		    {sets:new(), sets:new()},
		    Objects),
    Size = length(Objects),
    {Set, MissingSet, Size}.
