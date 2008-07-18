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
-export([start_link/0, query_state/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, { timer = none }).

-define(SERVER, ?MODULE).
-define(PERSIST_TIME, 300). % Every 300 secs, may be done configurable.

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
    {ok, TRef} = timer:send_interval(timer:seconds(?PERSIST_TIME), self(), persist),
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
    case etorrent_piece_diskstate:select(TM#tracking_map.filename) of
	[] -> {reply, unknown, S};
	[R] -> {reply, R#piece_diskstate.state, S}
    end;
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
    {atomic, Torrents} = etorrent_tracking_map:all(),
    prune_disk_state(Torrents),
    persist_disk_state(Torrents),
    etorrent_event_mgr:persisted_state_to_disk(),
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
prune_disk_state(Tracking) ->
    TrackedSet = sets:from_list(
		   [T#tracking_map.filename || T <- Tracking]),
    ok = etorrent_piece_diskstate:prune(TrackedSet).

%%--------------------------------------------------------------------
%% Func: persist_disk_state(Tracking) -> ok
%% Description: Persist state on disk
%%--------------------------------------------------------------------
persist_disk_state([]) ->
    ok;
persist_disk_state([#tracking_map { id = Id,
				    filename = FName} | Next]) ->
    case etorrent_torrent:select(Id) of
	[] -> persist_disk_state(Next);
	[S] -> case S#torrent.state of
		   seeding ->
		       etorrent_piece_diskstate:new(FName, seeding);
		   leeching ->
		       BitField = etorrent_piece:bitfield(Id),
		       etorrent_piece_diskstate:new(FName, {bitfield, BitField});
		   endgame ->
		       BitField = etorrent_piece:bitfield(Id),
	    etorrent_piece_diskstate:new(FName, {bitfield, BitField});
		   unknown ->
		       ok
	       end,
	       persist_disk_state(Next)
    end.



