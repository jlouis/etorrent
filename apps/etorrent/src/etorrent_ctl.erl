%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Control torrents globally
%% <p>This module is used to globally control torrents. You can start
%% a torrent by pointing to a file on disk, and you can stop or a
%% check a torrent.</p>
%% <p>As such, this module is <em>intended</em> to become an API for
%% torrent manipulation in the long run.</p>
%% @end
-module(etorrent_ctl).
-behaviour(gen_server).

-include("log.hrl").

-export([start_link/1,

         start/1, stop/1,
         check/1]).

-export([handle_cast/2, handle_call/3, init/1, terminate/2]).
-export([handle_info/2, code_change/3]).

-define(SERVER, ?MODULE).


-record(state, {local_peer_id}).
-ignore_xref([{start_link, 1}]).

%% API

%% =======================================================================

% @doc Start a new etorrent_t_manager process
% @end
-spec start_link(binary()) -> {ok, pid()} | ignore | {error, term()}.
start_link(PeerId) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [PeerId], []).

% @doc Ask the manager process to start a new torrent, given in File.
% @end
-spec start(string()) -> ok.
start(File) ->
    gen_server:cast(?SERVER, {start, File}).

% @doc Check a torrents contents
% @end
-spec check(integer()) -> ok.
check(Id) ->
    gen_server:cast(?SERVER, {check, Id}).

% @doc Ask the manager process to stop a torrent, identified by File.
% @end
-spec stop(string()) -> ok.
stop(File) ->
    gen_server:cast(?SERVER, {stop, File}).

%% =======================================================================

%% @private
init([PeerId]) ->
    %% We trap exits to gracefully stop all torrents on death.
    process_flag(trap_exit, true),
    {ok, #state { local_peer_id = PeerId}}.

%% @private
handle_cast({start, F}, S) ->
    ?INFO([starting, F]),
    case torrent_duplicate(F) of
        true -> {noreply, S};
        false ->
            case etorrent_torrent_pool:start_child(F, S#state.local_peer_id,
						   etorrent_counters:next(torrent)) of
                {ok, _} -> {noreply, S};
                {error, {already_started, _Pid}} -> {noreply, S}
            end
    end;
handle_cast({check, Id}, S) ->
    Child = gproc:lookup_local_name({torrent, Id, control}),
    etorrent_torrent_ctl:check_torrent(Child),
    {noreply, S};
handle_cast({stop, F}, S) ->
    stop_torrent(F),
    {noreply, S}.

%% @private
handle_call(stop_all, _From, S) ->
    stop_all(),
    {reply, ok, S};
handle_call(_A, _B, S) ->
    {noreply, S}.

%% @private
handle_info(Info, State) ->
    ?WARN([unknown_info, Info]),
    {noreply, State}.

%% @private
terminate(_Event, _S) ->
    stop_all(),
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =======================================================================
stop_torrent(F) ->
    ?INFO([stopping, F]),
    case etorrent_table:get_torrent({filename, F}) of
	not_found -> ok; % Was already removed, it is ok.
	{value, _PL} ->
	    etorrent_torrent_pool:terminate_child(F),
	    ok
    end.

stop_all() ->
    PLS = etorrent_table:all_torrents(),
    [begin
	 F = proplists:get_value(filename, PL),
	 stop_torrent(F)
     end || PL <- PLS].

torrent_duplicate(F) ->
    case etorrent_table:get_torrent({filename, F}) of
	not_found -> false;
	{value, PL} ->
	    duplicate =:= proplists:get_value(state, PL)
    end.

