%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Supervise a pool of torrents.
%% @end
-module(etorrent_torrent_pool).

-behaviour(supervisor).

%% API
-export([start_link/0, start_child/3, terminate_child/1]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).
-ignore_xref([{'start_link', 0}]).

%% ====================================================================
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() -> supervisor:start_link({local, ?SERVER}, ?MODULE, []).

% @doc Add a new torrent file to the system
% <p>The torrent file is given by File. Our PeerId is also given, as well as
% the Id we wish to use for that torrent.</p>
% @end
-spec start_child(string(), binary(), integer()) ->
    {ok, pid()} | {ok, pid(), term()} | {error, term()}.
start_child(File, Local_PeerId, Id) ->
    ChildSpec = {File,
		 {etorrent_torrent_sup, start_link, [File, Local_PeerId, Id]},
		 transient, infinity, supervisor, [etorrent_torrent_sup]},
    supervisor:start_child(?SERVER, ChildSpec).

% @doc Ask to stop the torrent represented by File.
% @end
-spec terminate_child(string()) -> ok.
terminate_child(File) ->
    supervisor:terminate_child(?SERVER, File),
    supervisor:delete_child(?SERVER, File).

%% ====================================================================

%% @private
init([]) ->
    {ok,{{one_for_one, 5, 3600}, []}}.
