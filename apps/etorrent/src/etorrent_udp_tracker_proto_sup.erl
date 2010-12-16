%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Supervise the protocol decoder.
%% <p>We supervise the protocol decoder separately. This is to guard
%% against the case where we fail a decode. The decoder will restart
%% and we will be in business again. Of course, we have mitigation if
%% it dies too often, as per max_restart_frequency.</p>
%% @end
-module(etorrent_udp_tracker_proto_sup).

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

%% @private
init([]) ->
    Decoder = {decoder, {etorrent_udp_tracker_proto, start_link, []},
	       permanent, 2000, worker, [etorrent_udp_tracker_proto]},
    {ok, {{one_for_one, 1, 10}, [Decoder]}}.
