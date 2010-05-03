%%%-------------------------------------------------------------------
%%% File    : etorrent_fs_pool_sup.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Supervise a set of file system processes.
%%%
%%% Created : 21 Aug 2007 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_fs_pool_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, add_file_process/3]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the supervisor
%%--------------------------------------------------------------------
start_link() ->
    supervisor:start_link(?MODULE, []).

%%--------------------------------------------------------------------
%% Function: add_file_process/2
%% Description: Add a new process for maintaining a file.
%%--------------------------------------------------------------------
add_file_process(Pid, TorrentId, Path) ->
    supervisor:start_child(Pid, [Path, TorrentId]).

%%====================================================================
%% Supervisor callbacks
%%====================================================================
init([]) ->
    FSProcesses = {'FSPROCESS',
                   {etorrent_fs_process, start_link, []},
                   transient, 2000, worker, [etorrent_fs_process]},
    {ok, {{simple_one_for_one, 1, 60}, [FSProcesses]}}.

%%====================================================================
%% Internal functions
%%====================================================================
