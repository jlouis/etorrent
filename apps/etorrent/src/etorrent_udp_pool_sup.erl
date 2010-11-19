%%%-------------------------------------------------------------------
%%% File    : etorrent_udp_pool_sup.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% Description : Track a number of tracker_udp gen_fsm systems
%%%
%%% Created : 18 Nov 2010 by Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_udp_pool_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, add_udp_tracker/1]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

add_udp_tracker(Tracker) ->
    Sup = gproc:lookup_local_name(udp_tracker_pool),
    {ok, Pid} =
	supervisor:start_child(Sup, [Tracker]),
    {ok, Pid}.

%%====================================================================
init([]) ->
    gproc:add_local_name(udp_tracker_pool),
    ChildSpec = {child,
		 {etorrent_udp_tracker, start_link, []},
		 temporary, 5000, worker, [etorrent_udp_tracker]},
    {ok, {{simple_one_for_one, 3, 60}, [ChildSpec]}}.
