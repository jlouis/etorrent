%%%-------------------------------------------------------------------
%%% File    : etorrent_udp_tracker_sup.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% Description : Manage the UDP tracker parts of the system
%%%
%%% Created : 18 Nov 2010 by Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_udp_tracker_sup).

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
    TrackUdpPool = {tracker_udp_pool, {etorrent_udp_pool_sup,
				       start_link, []},
		    transient, infinity, supervisor, [etorrent_udp_pool_sup]},
    TrackUdpMgr = {tracker_udp_mgr, {etorrent_udp_tracker_mgr,
				     start_link, []},
		   permanent, 2000, worker, [tracker_udp_mgr]},
    DecoderSup = {tracker_udp_decoder, {etorrent_udp_tracker_proto_sup,
					start_link, []},
		  transient, infinity, supervisor, [etorrent_udp_tracker_proto_sup]},
    {ok,{{one_for_all,1,60}, [DecoderSup, TrackUdpPool, TrackUdpMgr]}}.

%%====================================================================
