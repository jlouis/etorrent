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
-include("log.hrl").

%% API
-export([start_link/1, add_peer/7]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%% ====================================================================
-spec start_link(integer()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Id) -> supervisor:start_link(?MODULE, [Id]).

% @doc Add a peer to the supervisor pool.
% <p>Post-factum, when new peers arrives, or we deplete the number of connected
% peer below a certain threshold, we add new peers. When this happens, we call
% the add_peer/7 function given here. It sets up a peer and adds it to the
% supervisor.</p>
% @end
-spec add_peer(pid(), binary(), binary(), integer(), {ip(), integer()},
	       [capabilities()], port()) ->
            {error, term()} | {ok, pid(), pid()}.
add_peer(GroupPid, LocalPeerId, InfoHash, Id,
         {IP, Port}, Capabilities, Socket) ->
    case supervisor:start_child(GroupPid,
				[LocalPeerId, InfoHash,
				 Id,
				 {IP, Port},
				 Capabilities,
				 Socket]) of
        {ok, _Pid} ->
	    RecvPid = gproc:lookup_local_name({peer, Socket, receiver}),
	    ControlPid = gproc:lookup_local_name({peer, Socket, control}),
	    {ok, RecvPid, ControlPid};
        {error, Reason} ->
            ?ERR([{add_peer_error, Reason}]),
            {error, Reason}
    end.


%% ====================================================================
init([Id]) ->
    gproc:add_local_name({torrent, Id, peer_pool_sup}),
    ChildSpec = {child,
                 {etorrent_peer_sup, start_link, []},
                 temporary, infinity, supervisor, [etorrent_peer_sup]},
    {ok, {{simple_one_for_one, 15, 60}, [ChildSpec]}}.
