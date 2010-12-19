%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Handle a listener pool for incoming connections
%% @end
-module(etorrent_listen_sup).

-behaviour(supervisor).

-export([start_link/1, start_child/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).
-define(DEFAULT_SOCKET_INCREASE, 10).

%%====================================================================

%% @doc Start up the listener system
%% @end
start_link(PeerId) ->
    {ok, SPid} = supervisor:start_link({local, ?SERVER}, ?MODULE, [PeerId]),
    {ok, _Pid} = start_child(),
    {ok, SPid}.

start_child() ->
    supervisor:start_child(?MODULE, []).
%%====================================================================

init([PeerId]) ->
    Port = etorrent_config:listen_port(),
    {ok, LSock} = find_listen_socket(Port, ?DEFAULT_SOCKET_INCREASE),
    AcceptChild =
	{accept_child, {etorrent_acceptor, start_link,
			[PeerId, LSock]},
	 temporary, brutal_kill, worker, [etorrent_acceptor]},
    RestartStrategy = {simple_one_for_one, 100, 3600},
    {ok, {RestartStrategy, [AcceptChild]}}.

%%====================================================================

find_listen_socket(_Port, 0) ->
    {error, could_not_find_free_socket};
find_listen_socket(Port, N) ->
    case gen_tcp:listen(Port, [binary, inet, {active, false}]) of
        {ok, Socket} ->
            {ok, Socket};
        {error, eaddrinuse} ->
            find_listen_socket(Port+1, N-1)
    end.
