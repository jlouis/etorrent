%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Supervise a pool of torrents.
%% @end
-module(etorrent_torrent_pool).

-behaviour(supervisor).

%% API
-export([start_link/0, add_torrent/3, stop_torrent/1]).

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
-spec add_torrent(string(), binary(), integer()) ->
    {ok, pid()} | {ok, pid(), term()} | {error, term()}.
add_torrent(File, Local_PeerId, Id) ->
    supervisor:start_child(?SERVER, [File, Local_PeerId, Id]).

% @doc Ask to stop the torrent represented by File.
% @end
-spec stop_torrent(string()) -> ok.
stop_torrent(File) ->
    supervisor:terminate_child(?SERVER, File),
    supervisor:delete_child(?SERVER, File).

%% ====================================================================

%% @private
init([]) ->
    ChildSpec = {child,
		 {etorrent_torrent_sup, start_link, []},
		 transient, infinity, supervisor, [etorrent_torrent_sup]},
    {ok,{{one_for_one, 5, 3600}, [ChildSpec]}}.
