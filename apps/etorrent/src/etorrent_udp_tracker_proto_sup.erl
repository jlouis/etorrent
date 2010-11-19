%%%-------------------------------------------------------------------
%%% File    : etorrent_udp_tracker_proto_sup.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% Description : Supervise the protocol decoder
%%%
%%% Created : 18 Nov 2010 by Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_udp_tracker_proto_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
init([]) ->
    Decoder = {decoder, {etorrent_udp_tracker_proto, start_link, []},
	       permanent, 2000, worker, [etorrent_udp_tracker_proto]},
    {ok, {{one_for_one, 1, 10}, [Decoder]}}.
