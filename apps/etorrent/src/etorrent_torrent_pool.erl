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

-type bcode() :: etorrent_types:bcode().

%% ====================================================================
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() -> supervisor:start_link({local, ?SERVER}, ?MODULE, []).

% @doc Add a new torrent file to the system
% <p>The torrent file is given by its bcode representation, file name
% and info hash. Our PeerId is also given, as well as
% the Id we wish to use for that torrent.</p>
% @end
-spec start_child({bcode(), string(), binary()}, binary(), integer()) ->
    {ok, pid()} | {ok, pid(), term()} | {error, term()}.
start_child({Torrent, TorrentFile, TorrentIH}, Local_PeerId, Id) ->
    ChildSpec = {TorrentIH,
		 {etorrent_torrent_sup, start_link,
		 [{Torrent, TorrentFile, TorrentIH}, Local_PeerId, Id]},
		 transient, infinity, supervisor, [etorrent_torrent_sup]},
    supervisor:start_child(?SERVER, ChildSpec).

% @doc Ask to stop the torrent represented by its info_hash.
% @end
-spec terminate_child(binary()) -> ok.
terminate_child(TorrentIH) ->
    supervisor:terminate_child(?SERVER, TorrentIH),
    supervisor:delete_child(?SERVER, TorrentIH).

%% ====================================================================

%% @private
init([]) ->
    {ok,{{one_for_one, 5, 3600}, []}}.
