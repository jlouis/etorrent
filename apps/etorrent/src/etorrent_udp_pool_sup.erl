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
-export([start_link/0, start_requestor/2, start_announce/3]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_requestor(Tr, N) ->
    {ok, Pid} =
	supervisor:start_child(?SERVER, [requestor, Tr, N]),
    {ok, Pid}.

start_announce(From, Tracker, PL) ->
    {ok, Pid} =
	supervisor:start_child(?SERVER, [announce, From, Tracker, PL]),
    {ok, Pid}.

%%====================================================================
init([]) ->
    ChildSpec = {child,
		 {etorrent_udp_tracker, start_link, []},
		 temporary, 5000, worker, [etorrent_udp_tracker]},
    {ok, {{simple_one_for_one, 3, 60}, [ChildSpec]}}.
