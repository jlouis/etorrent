%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Supervise the pool of acceptors
%% <p>This module supervises 5 acceptor processes</p>
%% @end
-module(etorrent_acceptor_sup).

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

-define(DEFAULT_AMOUNT_OF_ACCEPTORS, 5).
-define(SERVER, ?MODULE).

-ignore_xref([{'start_link', 1}]).

%% @doc Starts the supervisor
%% @end
-spec start_link(string()) -> {ok, pid()} | ignore | {error, term()}.
start_link(PeerId) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, [PeerId]).

%%====================================================================

%% @private
init([PeerId]) ->
    Children = build_children(PeerId, ?DEFAULT_AMOUNT_OF_ACCEPTORS),
    {ok, {{one_for_one, 1, 60}, Children}}.

%%====================================================================
%% Internal functions
%%====================================================================

build_children(_PeerId, 0) -> [];
build_children(PeerId, N) ->
    Id = {acceptor, N},
    ChildSpec = {Id,
                 {etorrent_acceptor, start_link, [PeerId]},
                 permanent, 2000, worker, [etorrent_acceptor]},
    [ChildSpec | build_children(PeerId, N-1)].
