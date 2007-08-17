%%%-------------------------------------------------------------------
%%% File    : file_access_mapper.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Manages where different torrent files store their data
%%%
%%% Created : 11 Aug 2007 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_fs_mapper).

-behaviour(gen_server).

%% API
-export([start_link/0, install_map/1, fetch_map/0,
	 get_files/3, get_files_hash/3, get_pieces/2, fetched/5,
	 not_fetched/5, calculate_amount_left/1, convert_diskstate_to_set/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {file_access_map = none}).

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

%%--------------------------------------------------------------------
%% Function: install_map/1
%% Description: Install the FileDict for the sending Pid
%%--------------------------------------------------------------------
install_map(FileDict) ->
    gen_server:call(?SERVER, {install_map, FileDict}).

%%--------------------------------------------------------------------
%% Function: fetch_map/0
%% Description: Return the (read-only) ETS table.
%%--------------------------------------------------------------------
fetch_map() ->
    gen_server:call(?SERVER, fetch_map).

get_files(ETS, Handle, Pn) ->
    ets:match(ETS, {Handle, Pn, '_', '$1', '_'}).

get_files_hash(ETS, Handle, Pn) ->
    ets:match(ETS, {Handle, Pn, '$1', '$2', '_'}).

get_pieces(ETS, Handle) ->
    ets:match(ETS, {Handle, '$1', '$2', '$3', '$4'}).

fetched(Handle, PieceNum, Hash, Ops, Done) ->
    gen_server:call(?SERVER, {fetched, Handle, PieceNum, Hash, Ops, Done}).

not_fetched(Handle, PieceNum, Hash, Ops, Done) ->
    gen_server:call(?SERVER, {not_fetched, Handle, PieceNum, Hash, Ops, Done}).

calculate_amount_left(Handle) ->
    gen_server:call(?SERVER, {calculate_amount_left, Handle}).

convert_diskstate_to_set(Handle) ->
    gen_server:call(?SERVER, {convert_diskstate_to_set, Handle}).

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
    {ok, #state{ file_access_map =
		   ets:new(file_access_map, [named_table, bag])}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({install_map, FileDict}, {From, _Tag}, S) ->
    install_map_in_tracking_table(FileDict, From, S),
    {reply, ok, S};
handle_call(fetch_map, _From, S) ->
    {reply, S#state.file_access_map, S};
handle_call({fetched, Handle, Pn, H, O, D}, _From, S) ->
    set_fetched(Handle, Pn, H, O, D, S),
    {reply, ok, S};
handle_call({not_fetched, Handle, Pn, H, O, D}, _From, S) ->
    set_not_fetched(Handle, Pn, H, O, D, S),
    {reply, ok, S};
handle_call({convert_diskstate_to_set, Handle}, _From, S) ->
    Reply = convert_diskstate_to_set(Handle, S),
    {reply, Reply, S};
handle_call({calculate_amount_left, Handle}, _From, S) ->
    Reply = calculate_amount_left(Handle, S),
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
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({'DOWN', _R, process, Pid, _Reason}, S) ->
    ets:match_delete(S#state.file_access_map,
		     {Pid, '_', '_', '_', '_'}),
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
install_map_in_tracking_table(FileDict, Pid, S) ->
    erlang:monitor(process, Pid),
    dict:map(fun(PieceNumber, {Hash, Files, Done}) ->
		     case Done of
			 ok ->
			     ets:insert(
			       S#state.file_access_map,
			       {Pid, PieceNumber, Hash, Files, fetched});
			 not_ok ->
			     ets:insert(
			       S#state.file_access_map,
			       {Pid, PieceNumber, Hash, Files, not_fetched});
			 none ->
			     ets:insert(
			       S#state.file_access_map,
			       {Pid, PieceNumber, Hash, Files, not_fetched})
		     end
	      end,
	      FileDict),
    ok.

set_state(Handle, Pn, Hash, Ops, Done, State, S) ->
    ets:delete_object(S#state.file_access_map,
		      {Handle, Pn, Hash, Ops, Done}),
    ets:insert(S#state.file_access_map,
	       {Handle, Pn, Hash, Ops, State}).

set_fetched(Handle, P, H, O, D, S) ->
    set_state(Handle, P, H, O, D, fetched, S).

set_not_fetched(Handle, P, H, O, D, S) ->
    set_state(Handle, P, H, O, D, not_fetched, S).

size_of_ops(Ops) ->
    lists:foldl(fun ({_Path, _Offset, Size}, Total) ->
			Size + Total end,
		0,
		Ops).

get_all_pieces_of_torrent(Handle, S) ->
    ets:match(S#state.file_access_map,
			{Handle, '$1', '_', '$2', '$3'}).

calculate_amount_left(Handle, S) ->
    Objects = get_all_pieces_of_torrent(Handle, S),
    Sum = lists:foldl(fun([_Pn, Ops, Done], Sum) ->
			      case Done of
				  fetched ->
				      Sum + size_of_ops(Ops);
				  not_fetched ->
				      Sum
			      end
		      end,
		      0,
		      Objects),
    Sum.

convert_diskstate_to_set(Handle, S) ->
    Objects = get_all_pieces_of_torrent(Handle, S),
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
