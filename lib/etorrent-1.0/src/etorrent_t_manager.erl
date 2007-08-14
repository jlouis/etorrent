-module(etorrent_t_manager).
-behaviour(gen_server).

-include("etorrent_version.hrl").

-export([start_link/0, start_torrent/1, stop_torrent/1]).
-export([handle_cast/2, handle_call/3, init/1, terminate/2]).
-export([handle_info/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(RANDOM_MAX_SIZE, 1000000000).

-record(state, { tracking_map,
		 local_peer_id }).

%% API
start_link() ->
    gen_server:start_link({local, ?SERVER}, etorrent_t_manager, [], []).

start_torrent(File) ->
    gen_server:cast(?SERVER, {start_torrent, File}).

stop_torrent(File) ->
    gen_server:cast(?SERVER, {stop_torrent, File}).

%% Callbacks
init(_Args) ->
    {ok, #state { tracking_map = ets:new(torrent_tracking_table,
					 [named_table]),
		  local_peer_id = generate_peer_id()}}.

handle_cast({start_torrent, F}, S) ->
    spawn_new_torrent(F, S),
    {noreply, S};
handle_cast({stop_torrent, F}, S) ->
    [{F, TorrentSup}] = ets:lookup(S#state.tracking_map, F),
    ets:delete(S#state.tracking_map, {F, TorrentSup}),
    {noreply, S}.

handle_call(_A, _B, S) ->
    {noreply, S}.


% TODO: Handle 'DOWN'
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Foo, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions
spawn_new_torrent(F, S) ->
    {ok, TorrentSup} =
	etorrent_t_pool_sup:spawn_new_torrent(F, S#state.local_peer_id),
    sys:trace(TorrentSup, true),
    ets:insert(S#state.tracking_map, {F, TorrentSup}),
    erlang:monitor(process, TorrentSup).

%% Utility
generate_peer_id() ->
    Number = crypto:rand_uniform(0, ?RANDOM_MAX_SIZE),
    Rand = io_lib:fwrite("~B----------", [Number]),
    lists:flatten(io_lib:format("-ET~s-~12s", [?VERSION, Rand])).


