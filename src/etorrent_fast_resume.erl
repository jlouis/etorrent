%%%-------------------------------------------------------------------
%%% File    : etorrent_fast_resume.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Fast resume process
%%%
%%% Created : 16 Jul 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------
-module(etorrent_fast_resume).

-behaviour(gen_server).

-include("etorrent_mnesia_table.hrl").
-include("types.hrl").
-include("log.hrl").

%% API
-export([start_link/0, query_state/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, { timer = none }).

-define(SERVER, ?MODULE).
-define(PERSIST_TIME, timer:seconds(300)). % Every 300 secs, may be done configurable.

%%====================================================================
%% @doc Start up the server
%% @end
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Query for the state of TorrentId, Id.
%% <p>The function returns one of several possible values:</p>
%% <dl><dt>unknown</dt>
%%     <dd>The torrent is in an unknown state. This means we know nothing
%%         in particular about the torrent and we should simply load it as
%%         if we had just started it</dd>
%%     <dt>seeding</dt><dd>We are currently seeding this torrent</dd>
%%     <dt>{bitfield, BF}</dt>
%%     <dd>Here is the bitfield of known good pieces. The rest are in
%%         an unknown state.</dd>
%% </dl>
%% @end
-spec query_state(integer()) -> unknown | seeding | {bitfield, bitfield()}.
query_state(Id) ->
        gen_server:call(?SERVER, {query_state, Id}).

%% ==================================================================

%% Enter a torrent into the tracking table
track_torrent(#tracking_map { id = Id, filename = FName}) ->
    case etorrent_torrent:state(Id) of
        not_found -> ignore;
        {value, unknown} -> ignore;
        {value, seeding} -> ets:insert(?MODULE, {FName, seeding});
        {value, _Other}  -> ets:insert(?MODULE,
                                {FName, {bitfield, etorrent_piece_mgr:bitfield(Id)}})
    end.

%% Enter all torrents into a tracking table
track_in_ets_table(Lst) when is_list(Lst) ->
    [track_torrent(TM) || TM <- Lst].

%% Run a persistence operation
persist_to_disk() ->
    {atomic, Torrents} = etorrent_tracking_map:all(),
    _ = track_in_ets_table(Torrents),
    {ok, F} = application:get_env(etorrent, fast_resume_file),
    ok = ets:tab2file(etorrent_fast_resume, F, [{extended_info, [object_count, md5sum]}]),
    ok.

%% ==================================================================

init([]) ->
    process_flag(trap_exit, true),
    {ok, F} = application:get_env(etorrent, fast_resume_file),
    X = ets:file2tab(F, [{verify, true}]),
    _ = case X of
        {ok, etorrent_fast_resume} -> true;
        E ->
            ?INFO([fast_resume_no_data, E]),
            _ = ets:new(etorrent_fast_resume, [named_table, private])
    end,
    {ok, TRef} = timer:send_interval(?PERSIST_TIME, self(), persist),
    {ok, #state{ timer = TRef}}.

handle_call({query_state, Id}, _From, S) ->
    {atomic, [TM]} = etorrent_tracking_map:select(Id),
    case ets:lookup(etorrent_fast_resume, TM#tracking_map.filename) of
        [] -> {reply, unknown, S};
        [{_, R}] -> {reply, R, S}
    end;
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(persist, S) ->
    ?INFO([persist_to_disk]),
    persist_to_disk(),
    {noreply, S};
handle_info(_Info, State) ->
    {noreply, State}.


terminate(normal, _State) ->
    persist_to_disk(),
    ok;
terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
