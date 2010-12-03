%%%-------------------------------------------------------------------
%%% File    : listener.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% License : See COPYING
%%% Description : Listen for incoming connections
%%%
%%% Created : 30 Jul 2007 by Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_listener).

-behaviour(gen_server).

%% API
-export([start_link/0, get_socket/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, { listen_socket = none}).

-define(SERVER, ?MODULE).
-define(DEFAULT_SOCKET_INCREASE, 10).

-ignore_xref({start_link, 0}).

%% ====================================================================
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

% @doc Return the listen socket we are bound to.
% @end
-spec get_socket() -> {ok, port()}.
get_socket() ->
    gen_server:call(?SERVER, get_socket).

%% --------------------------------------------------------------------
find_listen_socket(_Port, 0) ->
    {error, could_not_find_free_socket};
find_listen_socket(Port, N) ->
    case gen_tcp:listen(Port, [binary, inet, {active, false}]) of
        {ok, Socket} ->
            {ok, Socket};
        {error, eaddrinuse} ->
            find_listen_socket(Port+1, N-1)
    end.

%% ====================================================================

init([]) ->
    Port = etorrent_config:listen_port(),
    {ok, ListenSocket} = find_listen_socket(Port, ?DEFAULT_SOCKET_INCREASE),
    {ok, #state{ listen_socket = ListenSocket}}.

handle_call(get_socket, _From, S) ->
    {reply, {ok, S#state.listen_socket}, S};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

%% Make sure we close the socket again.
terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
