%%%-------------------------------------------------------------------
%%% File    : torrent_sup.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus.local.domain>
%%% Description : Supervision of torrent modules.
%%%
%%% Created : 13 Jul 2007 by Jesper Louis Andersen <jlouis@succubus.local.domain>
%%%-------------------------------------------------------------------
-module(torrent_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, add_control/1]).

%% Supervisor callbacks
-export([init/1]).

%%====================================================================
%% API functions
%%====================================================================
start_link() ->
    supervisor:start_link(?MODULE, []).

%% TODO We can simplify torrent_control, by feeding it stuff here!
%%   it removes a state inside torrent_control, so that is good.
add_control(Pid) ->
    supervisor:start_child(Pid, {torrent_control,
				 {torrent_control, start_link, []},
				 permanent, 10000, worker, [torrent_control]}).

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
init([]) ->
    {ok, {{one_for_all, 1, 60}, []}}.

%%====================================================================
%% Internal functions
%%====================================================================
