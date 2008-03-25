%%%
%%% This module is responsible for managing the run of set of torrent files.
%%%
-module(etorrent_t_manager).
-behaviour(gen_server).

-include_lib("stdlib/include/qlc.hrl").

-include("etorrent_version.hrl").
-include("etorrent_mnesia_table.hrl").

-export([start_link/0, start_torrent/1, stop_torrent/1]).
-export([handle_cast/2, handle_call/3, init/1, terminate/2]).
-export([handle_info/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(RANDOM_MAX_SIZE, 1000000000).

-record(state, {local_peer_id}).

%% API

%% Start a new etorrent_t_manager process
start_link() ->
    gen_server:start_link({local, ?SERVER}, etorrent_t_manager, [], []).

%% Ask the manager process to start a new torrent, given in File.
start_torrent(File) ->
    gen_server:cast(?SERVER, {start_torrent, File}).

%% Ask the manager process to stop a torrent, identified by File.
stop_torrent(File) ->
    gen_server:cast(?SERVER, {stop_torrent, File}).

%% Callbacks
init(_Args) ->
    {ok, #state { local_peer_id = generate_peer_id()}}.

handle_cast({start_torrent, F}, S) ->
    spawn_new_torrent(F, S),
    {noreply, S};
handle_cast({stop_torrent, F}, S) ->
    stop_torrent(F, S),
    {noreply, S}.


handle_call(_A, _B, S) ->
    {noreply, S}.

handle_info({'DOWN', _R, process, Pid, _Reason}, S) ->
    error_logger:info_msg("Got Down Msg ~p~n", [Pid]),
    delete_torrent_by_pid(Pid),
    {noreply, S};
handle_info(Info, State) ->
    error_logger:info_msg("Unknown message: ~p~n", [Info]),
    {noreply, State}.

terminate(_Foo, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions
spawn_new_torrent(F, S) ->
    T = fun() ->
		{ok, TorrentSup} =
		    etorrent_t_pool_sup:add_torrent(F, S#state.local_peer_id),
		erlang:monitor(process, TorrentSup),
		mnesia:write(#tracking_map { filename = F, supervisor_pid = TorrentSup })
	end,
    mnesia:transaction(T).

stop_torrent(F, S) ->
    error_logger:info_msg("Stopping ~p~n", [F]),
    Query = qlc:q([T#tracking_map.filename || T <- mnesia:table(tracking_map),
					      T#tracking_map.filename == F]),
    case qlc:e(Query) of
	[F] ->
	    etorrent_t_pool_sup:stop_torrent(F);
	[] ->
	    % Already stopped, do nothing, silently ignore
	    ok
    end,
    {noreply, S}.

delete_torrent_by_pid(Pid) ->
    F = fun() ->
		Query = qlc:q([T#tracking_map.filename || T <- mnesia:table(tracking_map),
				    T#tracking_map.supervisor_pid == Pid]),
		lists:foreach(fun (F) -> mnesia:delete(tracking_map, F, write) end, qlc:e(Query))
	end,
    mnesia:transaction(F).

generate_peer_id() ->
    Number = crypto:rand_uniform(0, ?RANDOM_MAX_SIZE),
    Rand = io_lib:fwrite("~B----------", [Number]),
    lists:flatten(io_lib:format("-ET~s-~12s", [?VERSION, Rand])).
