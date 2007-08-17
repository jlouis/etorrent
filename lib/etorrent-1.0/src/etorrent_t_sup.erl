%%%-------------------------------------------------------------------
%%% File    : etorrent_t_sup.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus.local.domain>
%%% License : See COPYING
%%% Description : Supervision of torrent modules.
%%%
%%% Created : 13 Jul 2007 by
%%%     Jesper Louis Andersen <jlouis@succubus.local.domain>
%%%-------------------------------------------------------------------
-module(etorrent_t_sup).

-behaviour(supervisor).

%% API
-export([start_link/2, add_filesystem/2, add_peer_master/6,
	 add_tracker/6, add_state/3, add_peer_pool/1]).

%% Supervisor callbacks
-export([init/1]).

%%====================================================================
%% API functions
%%====================================================================
start_link(File, Local_PeerId) ->
    supervisor:start_link(?MODULE, [File, Local_PeerId]).

%%--------------------------------------------------------------------
%% Func: add_filesystem/1
%% Description: Add a filesystem process to the torrent.
%%--------------------------------------------------------------------
add_filesystem(Pid, IDHandle) ->
    FS = {fs,
	  {etorrent_fs, start_link, [IDHandle]},
	  temporary, 2000, worker, [etorrent_fs]},
    % TODO: Handle some cases here if already added.
    supervisor:start_child(Pid, FS).

add_peer_master(Pid, GroupPid, Local_Peer_Id,
		InfoHash, StatePid, FileSystemPid) ->
    PeerGroup = {peer_group,
		  {etorrent_t_peer_group, start_link,
		   [Local_Peer_Id, GroupPid,
		    InfoHash, StatePid, FileSystemPid]},
		  temporary, 60000, worker, [etorrent_t_peer_group]},
    supervisor:start_child(Pid, PeerGroup).

add_tracker(Pid, StatePid, PeerGroupPid, URL, InfoHash, Local_Peer_Id) ->
    Tracker = {tracker_communication,
	       {etorrent_tracker_communication, start_link,
		[self(), StatePid, PeerGroupPid, URL, InfoHash, Local_Peer_Id]},
	       temporary, 60000, worker, [etorrent_tracker_communication]},
    supervisor:start_child(Pid, Tracker).

add_state(Pid, PieceLength, ControlPid) ->
    State = {state,
	     {etorrent_t_state, start_link,
	      [PieceLength, ControlPid]},
	     temporary, 5000, worker, [etorrent_t_state]},
    supervisor:start_child(Pid, State).

add_peer_pool(Pid) ->
    Group = {peer_pool,
	     {etorrent_t_peer_pool_sup, start_link, []},
	     transient, infinity, supervisor, [etorrent_t_peer_group]},
    supervisor:start_child(Pid, Group).

%%====================================================================
%% Supervisor callbacks
%%====================================================================
%%--------------------------------------------------------------------
%% Func: init(Args) -> {ok,  {SupFlags,  [ChildSpec]}} |
%%                     ignore                          |
%%                     {error, Reason}
%% Description: Whenever a supervisor is started using
%% supervisor:start_link/[2,3], this function is called by the new process
%% to find out about restart strategy, maximum restart frequency and child
%% specifications.
%%--------------------------------------------------------------------
init([File, Local_PeerId]) ->
    Control =
	{control,
	 {etorrent_t_control, start_link_load, [File, Local_PeerId]},
	 permanent, 60000, worker, [etorrent_t_control]},
    {ok, {{one_for_all, 1, 60}, [Control]}}.

%%====================================================================
%% Internal functions
%%====================================================================
