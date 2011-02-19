%%%-------------------------------------------------------------------
%%% @author Jesper Louis andersen <jesper.louis.andersen@gmail.com>
%%% @copyright (C) 2011, Jesper Louis andersen
%%% @doc Supervisor for the gen_utp framework
%%% @end
-module(gen_utp_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%%===================================================================

%% @private
init([]) ->
    RestartStrategy = all_for_one,
    MaxRestarts = 10,
    MaxSecondsBetweenRestarts = 3600,

    SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},

    GenUTP = {gen_utp, {gen_utp, start_link, []},
	      permanent, 15000, worker, [gen_utp]},
    WorkerPool = {gen_utp_worker_pool, {gen_utp_worker_pool, start_link, []},
		  transient, infinity, supervisor, [gen_utp_worker_pool]},
    {ok, {SupFlags, [WorkerPool, GenUTP]}}.

