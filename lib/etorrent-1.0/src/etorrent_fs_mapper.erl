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
	 get_files_hash/3,
	 calculate_amount_left/1, convert_diskstate_to_set/1,
	 torrent_completed/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {}).

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

get_files_hash(ETS, Handle, Pn) ->
    ets:match(ETS, {Handle, Pn, '$1', '$2', '_'}).

calculate_amount_left(Handle) ->
    gen_server:call(?SERVER, {calculate_amount_left, Handle}).

convert_diskstate_to_set(Handle) ->
    gen_server:call(?SERVER, {convert_diskstate_to_set, Handle}).

torrent_completed(Handle) ->
    gen_server:call(?SERVER, {torrent_completed, Handle}).

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
handle_call({install_map, FileDict}, {From, _Tag}, S) ->
    install_map_in_tracking_table(FileDict, From),
    {reply, ok, S};
handle_call({convert_diskstate_to_set, Handle}, _From, S) ->
    Reply = convert_diskstate_to_set(Handle, S),
    {reply, Reply, S};
handle_call({calculate_amount_left, Handle}, _From, S) ->
    Reply = calculate_amount_left(Handle, S),
    {reply, Reply, S};
handle_call({torrent_completed, Handle}, _From, S) ->
    Reply = is_torrent_completed(Handle, S),
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
handle_info({'DOWN', _R, process, _Pid, _Reason}, S) ->
%%    ets:match_delete(S#state.file_access_map,
%%		     {Pid, '_', '_', '_', '_'}),
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
install_map_in_tracking_table(FileDict, Pid) ->
    erlang:monitor(process, Pid),
    etorrent_mnesia_operations:file_access_insert(Pid, FileDict),
    ok.

size_of_ops(Ops) ->
    lists:foldl(fun ({_Path, _Offset, Size}, Total) ->
			Size + Total end,
		0,
		Ops).

get_all_pieces_of_torrent(Handle, _S) ->
    etorrent_mnesia_operations:file_access_torrent_pieces(Handle).

calculate_amount_left(Handle, S) ->
    Objects = get_all_pieces_of_torrent(Handle, S),
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

is_torrent_completed(Handle, _S) ->
    etorrent_mnesia_operations:file_access_is_complete(Handle).

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
