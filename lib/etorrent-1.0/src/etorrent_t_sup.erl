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
-export([start_link/3, add_peer_group/4, add_tracker/6, get_pid/2]).

%% Supervisor callbacks
-export([init/1]).

%%====================================================================
%% API functions
%%====================================================================
start_link(File, Local_PeerId, Id) ->
    supervisor:start_link(?MODULE, [File, Local_PeerId, Id]).

%%--------------------------------------------------------------------
%% Func: get_pid/2
%% Args: Pid ::= pid() - Pid of the supervisor
%%       Name ::= atom() - the atom the pid is identified by
%% Description: Return the Pid of the peer group process.
%%--------------------------------------------------------------------
get_pid(Pid, Name) ->
    {value, {_, Child, _, _}} =
	lists:keysearch(Name, 1, supervisor:which_children(Pid)),
    Child.

%%--------------------------------------------------------------------
%% Func: add_filesystem/3
%% Description: Add a filesystem process to the torrent.
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Func: add_file_system_pool/1
%% Description: Add a filesystem process to the torrent.
%%--------------------------------------------------------------------

add_peer_group(Pid, Local_Peer_Id, InfoHash, TorrentId) ->
    GroupPid = get_pid(Pid, peer_pool_sup),
    FSPid = get_pid(Pid, fs),
    PeerGroup = {peer_group,
		  {etorrent_t_peer_group_mgr, start_link,
		   [Local_Peer_Id, GroupPid,
		    InfoHash, FSPid, TorrentId]},
		  permanent, 2000, worker, [etorrent_t_peer_group]},
    supervisor:start_child(Pid, PeerGroup).

add_tracker(Pid, PeerGroupPid, URL, InfoHash, Local_Peer_Id, TorrentId) ->
    Tracker = {tracker_communication,
	       {etorrent_tracker_communication, start_link,
		[self(), PeerGroupPid, URL, InfoHash, Local_Peer_Id, TorrentId]},
	       permanent, 15000, worker, [etorrent_tracker_communication]},
    supervisor:start_child(Pid, Tracker).

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
init([Path, PeerId, Id]) ->
    Control = {control,
	       {etorrent_t_control, start_link, [Id, Path, PeerId]},
	       permanent, 20000, worker, [etorrent_t_control]},
    FSPool = {fs_pool,
	      {etorrent_fs_pool_sup, start_link, []},
	      transient, infinity, supervisor, [etorrent_fs_pool_sup]},
    FS = {fs,
	  {etorrent_fs, start_link, [Id, self()]},
	  permanent, 2000, worker, [etorrent_fs]},
    PeerPool = {peer_pool_sup,
		{etorrent_t_peer_pool_sup, start_link, []},
		transient, infinity, supervisor, [etorrent_t_peer_pool_sup]},
    {ok, {{one_for_all, 1, 60}, [Control, FSPool, FS, PeerPool]}}.

%%====================================================================
%% Internal functions
%%====================================================================
