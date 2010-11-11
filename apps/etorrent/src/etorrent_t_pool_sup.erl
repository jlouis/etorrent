%%%-------------------------------------------------------------------
%%% File    : etorrent_t_pool_sup.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% License : See COPYING
%%% Description : Supervisor for the pool of torrents
%%%
%%% Created : 13 Jul 2007 by
%%%     Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_t_pool_sup).

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
    Torrent = {File,
               {etorrent_t_sup, start_link, [File, Local_PeerId, Id]},
               transient, infinity, supervisor, [etorrent_t_sup]},
    supervisor:start_child(?SERVER, Torrent).

% @doc Ask to stop the torrent represented by File.
% @end
-spec stop_torrent(string()) -> ok.
stop_torrent(File) ->
    supervisor:terminate_child(?SERVER, File),
    supervisor:delete_child(?SERVER, File).

%% ====================================================================
init([]) ->
    {ok,{{one_for_one, 5, 60}, []}}.
