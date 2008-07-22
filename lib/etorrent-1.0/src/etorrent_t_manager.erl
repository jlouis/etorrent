%%%
%%% This module is responsible for managing the run of set of torrent files.
%%%
-module(etorrent_t_manager).
-behaviour(gen_server).

-include("etorrent_version.hrl").
-include("etorrent_mnesia_table.hrl").

-export([start_link/0, start_torrent/1, stop_torrent/1,
	 check_torrent/1]).
-export([handle_cast/2, handle_call/3, init/1, terminate/2]).
-export([handle_info/2, code_change/3]).
-export([generate_peer_id/0]).

-define(SERVER, ?MODULE).
-define(RANDOM_MAX_SIZE, 999999999999).

-record(state, {local_peer_id}).

%% API

%% Start a new etorrent_t_manager process
start_link() ->
    gen_server:start_link({local, ?SERVER}, etorrent_t_manager, [], []).

%% Ask the manager process to start a new torrent, given in File.
start_torrent(File) ->
    gen_server:cast(?SERVER, {start_torrent, File}).

%% Check a torrents contents
check_torrent(Id) ->
    gen_server:cast(?SERVER, {check_torrent, Id}).

%% Ask the manager process to stop a torrent, identified by File.
stop_torrent(File) ->
    gen_server:cast(?SERVER, {stop_torrent, File}).

%% Callbacks
init(_Args) ->
    {ok, #state { local_peer_id = generate_peer_id()}}.

handle_cast({start_torrent, F}, S) ->
    {ok, _} =
	etorrent_t_pool_sup:add_torrent(F, S#state.local_peer_id, etorrent_sequence:next(torrent)),
    {noreply, S};
handle_cast({check_torrent, Id}, S) ->
    {atomic, [T]} = etorrent_tracking_map:select(Id),
    SPid = T#tracking_map.supervisor_pid,
    Child = etorrent_t_sup:get_pid(SPid, control),
    etorrent_t_control:check_torrent(Child),
    {noreply, S};
handle_cast({stop_torrent, F}, S) ->
    stop_torrent(F, S).

handle_call(_A, _B, S) ->
    {noreply, S}.

handle_info(Info, State) ->
    error_logger:info_msg("Unknown message: ~p~n", [Info]),
    {noreply, State}.

terminate(_Foo, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions
stop_torrent(F, S) ->
    error_logger:info_msg("Stopping ~p~n", [F]),
    case etorrent_tracking_map:select({filename, F}) of
	{atomic, [T]} when is_record(T, tracking_map) ->
	    etorrent_t_pool_sup:stop_torrent(F),
	    ok;
	{atomic, []} ->
	    %% Was already removed, it is ok.
	    ok
    end,
    {noreply, S}.

generate_peer_id() ->
    Number = crypto:rand_uniform(0, ?RANDOM_MAX_SIZE),
    Rand = io_lib:fwrite("~B----------", [Number]),
    PeerId = lists:flatten(io_lib:format("-ET~s-~12s", [?VERSION, Rand])),
    error_logger:info_report([peer_id, PeerId]),
    PeerId.
