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
-export([start_link/2, add_filesystem/2]).

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
