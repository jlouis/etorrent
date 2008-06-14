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
-export([start_link/3, add_file_system/3, add_peer_group/7,
	 add_tracker/6, add_peer_pool/1,
	 add_file_system_pool/1]).

%% Supervisor callbacks
-export([init/1]).

%%====================================================================
%% API functions
%%====================================================================
start_link(File, Local_PeerId, Id) ->
    supervisor:start_link(?MODULE, [File, Local_PeerId, Id]).

%%--------------------------------------------------------------------
%% Func: add_filesystem/3
%% Description: Add a filesystem process to the torrent.
%%--------------------------------------------------------------------
add_file_system(Pid, FSPool, IDHandle) when is_integer(IDHandle) ->
    FS = {fs,
	  {etorrent_fs, start_link, [IDHandle, FSPool]},
	  temporary, 2000, worker, [etorrent_fs]},
    case supervisor:start_child(Pid, FS) of
	{ok, ChildPid} ->
	    {ok, ChildPid};
	{error, {already_started, ChildPid}} -> % Could be copied to other add_X calls.
	    {ok, ChildPid}
    end.

%%--------------------------------------------------------------------
%% Func: add_file_system_pool/1
%% Description: Add a filesystem process to the torrent.
%%--------------------------------------------------------------------
add_file_system_pool(Pid) ->
    FSPool = {fs_pool,
	      {etorrent_fs_pool_sup, start_link, []},
	      transient, infinity, supervisor, [etorrent_fs_pool_sup]},
    supervisor:start_child(Pid, FSPool).

add_peer_group(Pid, GroupPid, Local_Peer_Id,
		InfoHash, FileSystemPid, TorrentState, TorrentId) ->
    PeerGroup = {peer_group,
		  {etorrent_t_peer_group, start_link,
		   [Local_Peer_Id, GroupPid,
		    InfoHash, FileSystemPid, TorrentState, TorrentId]},
		  temporary, 2000, worker, [etorrent_t_peer_group]},
    supervisor:start_child(Pid, PeerGroup).

add_tracker(Pid, PeerGroupPid, URL, InfoHash, Local_Peer_Id, TorrentId) ->
    Tracker = {tracker_communication,
	       {etorrent_tracker_communication, start_link,
		[self(), PeerGroupPid, URL, InfoHash, Local_Peer_Id, TorrentId]},
	       temporary, 90000, worker, [etorrent_tracker_communication]},
    supervisor:start_child(Pid, Tracker).

add_peer_pool(Pid) ->
    Group = {peer_pool_sup,
	     {etorrent_t_peer_pool_sup, start_link, []},
	     transient, infinity, supervisor, [etorrent_t_peer_pool_sup]},
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
init([File, Local_PeerId, Id]) ->
    Control =
	{control,
	 {etorrent_t_control, start_link_load, [File, Local_PeerId, Id]},
	 transient, 2000, worker, [etorrent_t_control]},
    {ok, {{one_for_all, 1, 60}, [Control]}}.

%%====================================================================
%% Internal functions
%%====================================================================
