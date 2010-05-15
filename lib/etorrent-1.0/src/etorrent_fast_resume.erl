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

%% API
-export([start_link/0, query_state/1, stop/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, { timer = none }).

%% Type of the state in the diskstate in question.
-type(diskstate_state() :: 'seeding' | {'bitfield', binary()}).

%% Piece state on disk for persistence
-record(piece_diskstate, {filename :: string(), % Name of torrent
                          state :: diskstate_state()}).

-define(SERVER, ?MODULE).
-define(PERSIST_TIME, timer:seconds(300)). % Every 300 secs, may be done configurable.

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


%%--------------------------------------------------------------------
%% Function: query(Id) -> seeding | {bitfield, BitField} | unknown
%% Description: Query for the state of TorrentId, Id.
%%--------------------------------------------------------------------
query_state(Id) ->
        gen_server:call(?SERVER, {query_state, Id}).

%%--------------------------------------------------------------------
%% Function: stop()
%% Description: Stop the fast-resume server.
%%--------------------------------------------------------------------
stop() ->
    gen_server:call(?SERVER, stop).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([]) ->
    process_flag(trap_exit, true),
    {ok, F} = application:get_env(etorrent, fast_resume_file),
    X = ets:file2tab(F, [{verify, true}]),
    _ = case X of
        {ok, etorrent_fast_resume} -> true;
        E ->
            error_logger:info_report([fast_resume_no_data, E]),
            _ = ets:new(etorrent_fast_resume, [named_table, private])
    end,
    {ok, TRef} = timer:send_interval(?PERSIST_TIME, self(), persist),
    {ok, #state{ timer = TRef}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({query_state, Id}, _From, S) ->
    {atomic, [TM]} = etorrent_tracking_map:select(Id),
    case ets:lookup(etorrent_fast_resume, TM#tracking_map.filename) of
        [] -> {reply, unknown, S};
        [{_, R}] -> {reply, R#piece_diskstate.state, S}
    end;
handle_call(stop, _From, S) ->
    {stop, normal, ok, S};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(persist, S) ->
    error_logger:info_report([persist_to_disk]),
    persist_to_disk(),
    {noreply, S};
handle_info(_Info, State) ->
    {noreply, State}.


%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(normal, _State) ->
    persist_to_disk(),
    true = ets:delete(etorrent_fast_resume),
    ok;
terminate(_Reason, _State) ->
    ok.


%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Func: prune_disk_state(Tracking) -> ok
%% Description: Prune the persistent disk state for anything we are
%%   not tracking.
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Func: persist_disk_state(Tracking) -> ok
%% Description: Persist state on disk
%%--------------------------------------------------------------------
track_in_ets_table([]) -> ok;
track_in_ets_table([#tracking_map { id = Id,
                                    filename = FName} | Next]) ->
    {F, St} = case etorrent_torrent:state(Id) of
        not_found -> track_in_ets_table(Next); %% Not hot, skip it.
        {value, seeding}  -> {FName, seeding};
        {value, leeching} -> {FName, {bitfield, etorrent_piece_mgr:bitfield(Id)}};
        {value, endgame}  -> {FName, {bitfield, etorrent_piece_mgr:bitfield(Id)}};
        {value, unknown}  -> ok
    end,
    true = ets:insert(etorrent_fast_resume, #piece_diskstate{filename = F,
                                                             state    = St}),
    track_in_ets_table(Next).

persist_to_disk() ->
    {atomic, Torrents} = etorrent_tracking_map:all(),
    track_in_ets_table(Torrents),
    {ok, F} = application:get_env(etorrent, fast_resume_file),
    ok = ets:tab2file(etorrent_fast_resume, F, [{extended_info, [object_count, md5sum]}]),
    etorrent_event_mgr:persisted_state_to_disk(),
    ok.


