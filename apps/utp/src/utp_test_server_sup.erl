%%% @author Jesper Louis andersen <>
%%% @copyright (C) 2011, Jesper Louis andersen
%%% @doc
%%% Supervise a server for testing uTP
%%% @end
%%% Created : 12 Aug 2011 by Jesper Louis andersen <>
%%%-------------------------------------------------------------------
-module(utp_test_server_sup).

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================

%% @doc
%% Starts the supervisor
%% @end
start_link(Dir) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, [Dir]).

%%%===================================================================

%% @private
init([Dir]) ->
    PoolChild =
        {pool, {utp_test_server_pool_sup, start_link, []},
         permanent, infinity, supervisor, [utp_test_server_pool_sup]},
    FileMapper =
        {file_mapper, {utp_file_map, start_link, [Dir]},
         permanent, 5*1000, worker, [utp_file_map]},
    RestartStrategy = {one_for_one, 100, 3600},
    {ok, {RestartStrategy, [PoolChild, FileMapper]}}.

%%%===================================================================








