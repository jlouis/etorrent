%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Supervise the dirwatcher
%% <p>Minimal supervisor for maintaining the dirwatcher gen_server</p>
%% @end
-module(etorrent_dirwatcher_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).
-ignore_xref([{start_link, 0}]).
-define(SERVER, ?MODULE).

%% ====================================================================

%% @doc Start the supervisor
%% @end
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% @private
init([]) ->
    DirWatcher = {etorrent_dirwatcher,
                  {etorrent_dirwatcher, start_link, []},
                  permanent, 2000, worker, [etorrent_dirwatcher]},
    {ok,{{one_for_one,1,60}, [DirWatcher]}}.

%% ====================================================================
