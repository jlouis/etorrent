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
-export([start_link/1, add_file_process/3]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).
-ignore_xref([{'start_link', 1}]).
%% ====================================================================
% @doc Start up the supervisor
% @end
-spec start_link(integer()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Id) -> supervisor:start_link(?MODULE, [Id]).

% @doc Add a new process for maintaining a file.
% @end
-spec add_file_process(pid(), integer(), string(), pid()) ->
          {ok, pid()} | {error, term()} | {ok, pid(), term()}.
add_file_process(Pid, TorrentId, Path, ParentPid) ->
    supervisor:start_child(Pid, [Path, TorrentId, ParentPid]).

%% ====================================================================
init([Id]) ->
    gproc:add_local_name({torrent, Id, fs_pool}),
    FSProcesses = {'FSPROCESS',
                   {etorrent_fs_process, start_link, []},
                   transient, 2000, worker, [etorrent_fs_process]},
    {ok, {{simple_one_for_one, 1, 60}, [FSProcesses]}}.
