-module(torrent).
-behaviour(gen_server).

-export([handle_cast/2, handle_call/3, init/1, terminate/2]).
-export([handle_info/2, code_change/3]).

-export([start_link/3, start/1, stop/1]).

-author("jesper.louis.andersen@gmail.com").

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_info(_Foo, State) ->
    {noreply, State}.

start_link(F, Torrent, PeerId) ->
    gen_server:start_link(torrent, {F, Torrent, PeerId}, []).

start(TorrentPid) ->
    gen_server:cast(TorrentPid, start).

stop(TorrentPid) ->
    gen_server:cast(TorrentPid, stop).

init({F, Torrent, PeerId}) ->
    {ok, StatePid} = gen_server:start_link(torrent_state, [], []),
    {ok, TrackerDelegatePid} =
	gen_server:start_link(tracker_delegate,
			      {self(), StatePid,
			       metainfo:get_url(Torrent),
			       metainfo:get_infohash(Torrent),
			       PeerId}, []),
    io:format("Process for torrent ~s started~n", [F]),
    {ok, {F, Torrent, StatePid, TrackerDelegatePid}}.

handle_call(_Call, _Who, S) ->
    {noreply, S}.

terminate_children(_StatePid, _TrackerDelegatePid) ->
    ok.

terminate(shutdown, {_F, _Torrent, StatePid, TrackerDelegatePid}) ->
    terminate_children(StatePid, TrackerDelegatePid),
    ok.

handle_cast(start, {F, Torrent, StatePid, TrackerDelegatePid}) ->
    gen_server:cast(TrackerDelegatePid, start),
    {noreply, {F, Torrent, StatePid, TrackerDelegatePid}};
handle_cast(stop, {_F, _Torrent, StatePid, TrackerDelegatePid}) ->
    gen_server:cast(StatePid, stop),
    gen_server:cast(TrackerDelegatePid, stop);


%% These are Error cases. We should just try again later (Default request timeout value)
handle_cast({tracker_request_failed, Err}, State) ->
    error_logger:error_msg("Tracker request failed ~s~n", [Err]),
    {noreply, State};
handle_cast({tracker_responded_not_bcode, Err}, State) ->
    error_logger:error_msg("Tracker did not respond with a bcoded dict: ~s~n", [Err]),
    {noreply, State}.
