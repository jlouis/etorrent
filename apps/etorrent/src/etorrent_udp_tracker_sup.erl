%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Supervise the UDP tracker communication
%% <p>This supervisor is responsible for managing communication with
%% one or more UDP trackers. It manager a protocol decoder, a general
%% manager (which is the entry point for API users) and a Supervisor
%% pool of processes that handles a specific UDP tracker communictation.</p>
-module(etorrent_udp_tracker_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================

%% @doc Start the supervisor
%% @end
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
