%%% @author Jesper Louis andersen <>
%%% @copyright (C) 2011, Jesper Louis andersen
%%% @doc
%%% Supervise a server for testing uTP
%%% @end
%%% Created : 12 Aug 2011 by Jesper Louis andersen <>
%%%-------------------------------------------------------------------
-module(utp_test_server_pool_sup).

-behaviour(supervisor).

%% API
-export([start_link/0,
         start_child/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================

%% @doc
%% Starts the supervisor
%% @end
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_child() ->
    supervisor:start_child(?MODULE, []).

%%%===================================================================

%% @private
init([]) ->
    utp:start_app(3838, []),
    ok = gen_utp:listen([]),
    AcceptChild =
        {accept_child, {utp_test_server_acceptor, start_link,
                        []},
         temporary, brutal_kill, worker, [utp_test_server_acceptor]},
    RestartStrategy = {simple_one_for_one, 100, 3600},
    {ok, {RestartStrategy, [AcceptChild]}}.

%%%===================================================================






