-module(etorrent_tasks).
-define(SERVER, ?MODULE).
-define(TABLE, ?MODULE).

%% API for retriving information
-behaviour(gen_server).

-export([ lookup_tasks/0

        , lookup_tracks/1
        , lookup_tracks/2
        , reg_tracks/2

        , lookup_track_extractor/3
        , reg_track_extractor/3
        ]).


%% Supervisor's callbacks
-export([start_link/0]).

%% Behaviour API
-export([init/1,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-type torrent_id() :: integer().
-type file_id() :: integer().
-type track_id() :: integer().


lookup_tasks() ->
    gproc:lookup_local_properties(tasks).


-spec lookup_tracks(torrent_id()) -> [{file_id(), pid()}].
lookup_tracks(Tid) ->
    gproc:lookup_local_properties({file_tracks, Tid}).


-spec lookup_tracks(torrent_id(), file_id()) -> pid().
lookup_tracks(Tid, Fid) ->
    gproc:lookup_local_name({file_tracks, Tid, Fid}).


-spec reg_tracks(torrent_id(), file_id()) -> ok.
reg_tracks(Tid, Fid) ->
    gproc:add_local_name({file_tracks, Tid, Fid}),
    gproc:add_local_property({file_tracks, Tid}, Fid),
    Props = [ {type, file_tracks}
            , {torrent_id, Tid}
            , {file_id, Fid}],
    add_task(Props),
    ok.



-spec lookup_track_extractor(torrent_id(), file_id(), track_id()) -> pid().
lookup_track_extractor(TorrentId, FileId, TrackId) ->
    gproc:lookup_local_name({file_track_extractor, TorrentId, FileId, TrackId}).


-spec reg_track_extractor(torrent_id(), file_id(), track_id()) -> ok.
reg_track_extractor(TorrentId, FileId, TrackId) ->
    gproc:add_local_name({file_track_extractor, TorrentId, FileId, TrackId}),
    Props = [ {type, file_track_extractor}
            , {torrent_id, TorrentId}
            , {file_id, FileId}
            , {track_id, TrackId}],
    add_task(Props),
    ok.



add_task(Props) ->
    gproc:add_local_property(tasks, Props),
    gen_server:cast(?SERVER, {reg, self(), Props}).


% ------------------------------------------------------------------------    

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-record(state, {
    table :: integer()
}).

init([]) ->
    E = ets:new(?TABLE,[]),
    {ok, #state{table=E}}.


handle_cast({reg, Pid, Props}, State=#state{table=E}) ->
    etorrent_event:added_task(Props),
    Ref = erlang:monitor(process, Pid),
    true = ets:insert_new(E, {Ref, Props}),
    {noreply, State}.


handle_info({'DOWN',Ref,process,_Pid,Reason}, State=#state{table=E}) ->
    Props = ets:lookup_element(E, Ref, 2),
    true = ets:delete(E, Ref),
    case Reason of
        normal ->
            etorrent_event:completed_task(Props);
        _Error ->
            etorrent_event:failed_task(Props, Reason)
    end,
    {noreply, State}.


terminate(_, _) ->
    ok.


%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
