%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Supervise Request Event processes.
%% <p>A simple_one_for_one supervisor controlling a set of udp_tracker gen_servers.
%% </p>
%% @end
%%-------------------------------------------------------------------
-module(etorrent_udp_pool_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, start_requestor/2, start_announce/3]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================

%% @doc Start the supervisor
%% @end
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% @doc Start a new requestor child under the supervisor
%% @end
start_requestor(Tr, N) ->
    {ok, Pid} =
	supervisor:start_child(?SERVER, [requestor, Tr, N]),
    {ok, Pid}.

%% @doc Start a new announcer child under the supervisor
%% @end
start_announce(From, Tracker, PL) ->
    {ok, Pid} =
	supervisor:start_child(?SERVER, [announce, From, Tracker, PL]),
    {ok, Pid}.

%%====================================================================

%% @private
init([]) ->
    ChildSpec = {child,
		 {etorrent_udp_tracker, start_link, []},
		 temporary, 5000, worker, [etorrent_udp_tracker]},
    {ok, {{simple_one_for_one, 3, 60}, [ChildSpec]}}.
