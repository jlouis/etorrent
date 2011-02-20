%%% @author Jesper Louis andersen <jesper.louis.andersen@gmail.com>
%%% @copyright (C) 2011, Jesper Louis andersen
%%% @doc Worker pool of gen_utp_workers
%%% @end
-module(gen_utp_worker_pool).

-behaviour(supervisor).

%% API
-export([start_link/0]).
-export([start_child/4]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

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

%% @doc Start a worker child
start_child(Socket, Addr, Port, Options) ->
    Pool = gproc:lookup_local_name(gen_utp_worker_pool),
    supervisor:start_child(Pool, [Socket, Addr, Port, Options]).

%%%===================================================================

%% @private
init([]) ->
    gproc:add_local_name(gen_utp_worker_pool),

    ChildSpec = {child,
                 {gen_utp_worker, start_link, []},
                 temporary, 15000, worker, [gen_utp_worker]},
    {ok, {{simple_one_for_one, 50, 3600}, [ChildSpec]}}.











