%%%-------------------------------------------------------------------
%%% File    : etorrent_t_peer_pool_sup.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Supervise a group of peer processes.
%%%
%%% Created : 17 Aug 2007 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_peer_pool_sup).

-behaviour(supervisor).

-include("types.hrl").

%% API
-export([start_link/0, add_peer/7]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%% ====================================================================
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() -> supervisor:start_link(?MODULE, []).

% @doc Add a peer to the supervisor pool.
% <p>Post-factum, when new peers arrives, or we deplete the number of connected
% peer below a certain threshold, we add new peers. When this happens, we call
% the add_peer/7 function given here. It sets up a peer and adds it to the
% supervisor.</p>
% @end
-spec add_peer(pid(), binary(), binary(), pid(), integer(), {ip(), integer()}, port()) ->
            {error, term()} | {ok, pid(), pid()}.
add_peer(GroupPid, LocalPeerId, InfoHash, FilesystemPid, Id,
         {IP, Port}, Socket) ->
    case supervisor:start_child(GroupPid, [LocalPeerId, InfoHash,
                                                  FilesystemPid, Id,
                                                  {IP, Port}, Socket]) of
        {ok, Pid} ->
                {ok, RecvPid} = etorrent_peer_sup:get_pid(Pid, receiver),
                {ok, ControlPid} = etorrent_peer_sup:get_pid(Pid, control),
                {ok, RecvPid, ControlPid};
        {error, Reason} ->
            error_logger:error_report({add_peer_error, Reason}),
            {error, Reason}
    end.


%% ====================================================================
init([]) ->
    ChildSpec = {child,
                 {etorrent_peer_sup, start_link, []},
                 temporary, infinity, supervisor, [etorrent_peer_sup]},
    {ok, {{simple_one_for_one, 15, 60}, [ChildSpec]}}.
