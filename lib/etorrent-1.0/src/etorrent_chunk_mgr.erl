%%%-------------------------------------------------------------------
%%% File    : etorrent_chunk_mgr.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Chunk manager of etorrent.
%%%
%%% Created : 20 Jul 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------
-module(etorrent_chunk_mgr).

-include("etorrent_chunk.hrl").

-behaviour(gen_server).

%% API
-export([start_link/0, remove_chunks/2, store_chunk/4, putback_chunks/1,
	 mark_fetched/2, pick_chunks/4, endgame_remove_chunk/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {}).
-define(SERVER, ?MODULE).
-define(STORE_CHUNK_TIMEOUT, 20).
-define(PICK_CHUNKS_TIMEOUT, 20).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

mark_fetched(Id, {Index, Offset, Len}) ->
    gen_server:call(?SERVER, {mark_fetched, Id, Index, Offset, Len}).

store_chunk(Id, Index, {Offset, Len}, Pid) ->
    gen_server:call(?SERVER, {store_chunk, Id, Index, {Offset, Len}, Pid},
		   timer:seconds(?STORE_CHUNK_TIMEOUT)).

putback_chunks(Pid) ->
    gen_server:cast(?SERVER, {putback_chunks, Pid}).

remove_chunks(TorrentId, Index) ->
    gen_server:cast(?SERVER, {remove_chunks, TorrentId, Index}).

endgame_remove_chunk(Pid, Id, {Index, Offset, Len}) ->
    gen_server:call(?SERVER, {endgame_remove_chunk, Pid, Id, {Index, Offset, Len}}).

pick_chunks(Pid, Id, Set, N) ->
    gen_server:call(?SERVER, {pick_chunks, Pid, Id, Set, N},
		    timer:seconds(?PICK_CHUNKS_TIMEOUT)).

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
    _Tid = ets:new(etorrent_chunk_tbl, [set, protected, named_table,
					{keypos, 2}]),
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({mark_fetched, Id, Index, Offset, Len}, _From, S) ->
    R = etorrent_chunk:mark_fetched(Id, {Index, Offset, Len}),
    {reply, R, S};
handle_call({endgame_remove_chunk, Pid, Id, {Index, Offset, Len}}, _From, S) ->
    R = etorrent_chunk:endgame_remove_chunk(Pid, Id, {Index, Offset, Len}),
    {reply, R, S};
handle_call({store_chunk, Id, Index, {Offset, Len}, Pid}, _From, S) ->
    R = etorrent_chunk:store_chunk(Id, Index, {Offset, Len}, Pid),
    {reply, R, S};
handle_call({pick_chunks, Pid, Id, Set, PiecesToQueue}, _From, S) ->
    R = etorrent_chunk:pick_chunks(Pid, Id, Set, PiecesToQueue),
    {reply, R, S};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({putback_chunks, Pid}, S) ->
    {atomic, _} = etorrent_chunk:putback_chunks(Pid),
    {noreply, S};
handle_cast({remove_chunks, TorrentId, Index}, S) ->
    etorrent_chunk:remove_chunks(TorrentId, Index),
    {noreply, S};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
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
    ets:delete(etorrent_chunk_tbl),
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
