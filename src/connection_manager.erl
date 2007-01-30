%%%-------------------------------------------------------------------
%%% File    : connection_manager.erl
%%% Author  : User Jlouis <jlouis@succubus.localdomain>
%%% Description : 
%%%
%%% Created : 30 Jan 2007 by User Jlouis <jlouis@succubus.localdomain>
%%%-------------------------------------------------------------------
-module(connection_manager).
-behaviour(gen_server).

%% API
-export([is_interested/2, is_not_interested/2, start_link/4,
	 spawn_new_torrent/6]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {state_table = none,
		listen_socket = none,
		accept_pid = none,
		filesystem = none,
		peerid = none,
		infohash = none,
		managed_pids = none}).

%%====================================================================
%% API
%%====================================================================
start_link(PortToListen, FileSystemPid, PeerId, InfoHash) ->
    gen_server:start_link(?MODULE,
			  {PortToListen, FileSystemPid, PeerId, InfoHash}, []).

is_interested(Pid, PeerId) ->
    gen_server:cast(Pid, {is_interested, PeerId}).

is_not_interested(Pid, PeerId) ->
    gen_server:cast(Pid, {is_not_intersted, PeerId}).

spawn_new_torrent(Socket, FileSystem, Name, PeerId, InfoHash, S) ->
    Pid = torrent_peer:start_link(Socket, self(), FileSystem, Name, PeerId,
				  InfoHash),
    S#state{managed_pids = dict:store(Pid, PeerId, S#state.managed_pids)}.

spawn_listen_accept(ListenSocket, FileSystem, PeerId, InfoHash, Name) ->
    Pid = torrent_peer:start_link(self(),
				  FileSystem,
				  Name,
				  PeerId,
				  InfoHash),
    torrent_peer:startup_accept(Pid, ListenSocket),
    Pid.


%%====================================================================
%% gen_server callbacks
%%====================================================================
init({PortToListen, FileSystemPid, PeerId, InfoHash}) ->
    {ok, ListenSocket} = gen_tcp:listen(PortToListen,
					[binary, {active, false}]),
    AcceptPid = spawn_listen_accept(ListenSocket,
				    FileSystemPid,
				    PeerId,
				    InfoHash,
				    "FOO"),
    {ok, #state{state_table = ets:new(connection_table, []),
		listen_socket = ListenSocket,
		accept_pid = AcceptPid,
		filesystem = FileSystemPid,
		peerid = PeerId,
		infohash = InfoHash,
		managed_pids = dict:new()}}.

handle_call(Message, Who, State) ->
    error_logger:error_msg("M: ~s -- F: ~s~n", [Message, Who]),
    {noreply, State}.

handle_cast({new_ip, Port, IP}, S) ->
    Pid = torrent_peer:start_link(self(),
				  S#state.filesystem,
				  "FOO",
				  S#state.peerid,
				  S#state.infohash),
    torrent_peer:startup_connect(Pid, IP, Port),
    ets:insert_new(S#state.state_table, {Pid, unknown, not_interested, choked}),
    {noreply, S};
handle_cast(new_accept_needed, S) ->
    AcceptPid = spawn_listen_accept(S#state.listen_socket,
				    S#state.filesystem,
				    S#state.peerid,
				    S#state.infohash,
				    "FOO"),
    {noreply, S#state{accept_pid = AcceptPid}};
handle_cast({is_interested, PeerId}, State) ->
    [{_, _, Choke}] = ets:lookup(State, PeerId),
    {noreply, ets:insert_new(State, {PeerId, interested, Choke})};
handle_cast({is_not_interested, PeerId}, State) ->
    [{_, _, Choke}] = ets:lookup(State, PeerId),
    {norelpy, ets:insert_new(State, {PeerId, not_interested, Choke})};
handle_cast({choked, PeerId}, State) ->
    [{_, I, _}] = ets:lookup(State, PeerId),
    {noreply, ets:insert_new(State, {PeerId, I, choked})};
handle_cast({unchoked, PeerId}, State) ->
    [{_, I, _}] = ets:lookup(State, PeerId),
    {noreply, ets:insert_new(State, {PeerId, I, unchoked})}.

handle_info({'EXIT', Who, Reason}, S) ->
    error_logger:error_report([Who, Reason]),
    PeerId = dict:fetch(Who, S#state.managed_pids),
    ets:delete(PeerId, S#state.state_table),
    {noreply, S#state{managed_pids = dict:erase(Who, S#state.managed_pids)}};
handle_info(Message, State) ->
    error_logger:error_report([Message, State]),
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






