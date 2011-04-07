-module(etorrent_endgame).
-behaviour(gen_server).

%% exported functions
-export([start_link/1,
         is_active/1,
         activate/1]).

%% gproc registry entries
-export([register_server/1,
         lookup_server/1,
         await_server/1]).

%% gen_server callbacks
-export([init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3]).

-type pieceset()    :: etorrent_pieceset:pieceset().
-type torrent_id()  :: etorrent_types:torrent_id().
-type pieceindex()  :: etorrent_types:pieceindex().
-type chunkoffset() :: etorrent_types:chunkoffset().
-type chunklength() :: etorrent_types:chunklength().
-type chunkspec()   :: {pieceindex(), chunkoffset(), chunklength()}.

-record(state, {
    active   :: boolean(),
    pending  :: pid(),
    requests :: gb_tree()}).


server_name(TorrentID) ->
    {etorrent, TorrentID, endgame}.


%% @doc
%% @end
-spec register_server(torrent_id()) -> true.
register_server(TorrentID) ->
    etorrent_utils:register(server_name(TorrentID)).

%% @doc
%% @end
-spec lookup_server(torrent_id()) -> pid().
lookup_server(TorrentID) ->
    etorrent_utils:lookup(server_name(TorrentID)).

%% @doc
%% @end
-spec await_server(torrent_id()) -> pid().
await_server(TorrentID) ->
    etorrent_utils:await(server_name(TorrentID)).


%% @doc
%% @end
-spec start_link(torrent_id()) -> {ok, pid()}.
start_link(TorrentID) ->
    gen_server:start_link(?MODULE, [TorrentID], []).


%% @doc
%% @end
-spec is_active(pid()) -> boolean().
is_active(SrvPid) ->
    gen_server:call(SrvPid, is_active).


%% @doc
%% @end
-spec activate(pid()) -> ok.
activate(SrvPid) ->
    gen_server:call(SrvPid, activate).


%% @private
init([TorrentID]) ->
    true = register_server(TorrentID),
    Pending = etorrent_pending:await_server(TorrentID),
    InitState = #state{
        active=false,
        pending=Pending,
        requests=gb_trees:empty()},
    {ok, InitState}.


%% @private
handle_call(is_active, _, State) ->
    #state{active=IsActive} = State,
    {reply, IsActive, State};

handle_call(activate, _, State) ->
    #state{active=false} = State,
    NewState = State#state{active=true},
    {reply, ok, NewState};

handle_call({request_chunks, Pid, Peerset, _}, _, State) ->
    #state{pending=Pending, requests=Requests} = State,
    Request = etorrent_util:find(
        fun({{Index, _, _}, Peers}) ->
            etorrent_pieceset:is_member(Index, Peerset)
            and not lists:member(Pid, Peers)
        end, gb_trees:to_list(Requests)),
    case Request of
        false ->
            {reply, {ok, assigned}, State};
        {{Index, Offset, Length}=Chunk, Peers} ->
            etorrent_pending:mark_sent(Index, Offset, Length, Pid, Pending),
            NewRequests = gb_trees:update(Chunk, [Pid|Peers], Requests),
            NewState = State#state{requests=NewRequests},
            {reply, {ok, [Chunk]}, NewState}
    end.


%% @private
handle_cast(_, State) ->
    {stop, not_handled, State}.


%% @private
handle_info({mark_dropped, Pid, Index, Offset, Length}, State) ->
    #state{requests=Requests} = State,
    Chunk = {Index, Offset, Length},
    case gb_trees:lookup(Chunk, Requests) of
        none -> {noreply, State};
        {value, Peers} ->
            NewRequests = gb_trees:update(Chunk, Peers -- [Pid], Requests),
            NewState = State#state{requests=NewRequests},
            {noreply, NewState}
    end;

handle_info({mark_fetched, Pid, Index, Offset, Length}, State) ->
    #state{requests=Requests} = State,
    Chunk = {Index, Offset, Length},
    case gb_trees:lookup(Chunk, Requests) of
        none -> {noreply, State};
        {value, Peers} ->
            [etorrent_peer_control:cancel(Peer, Index, Offset, Length) || Peer <- Peers],
            NewRequests = gb_trees:delete(Chunk, Requests),
            NewState = State#state{requests=NewRequests},
            {noreply, NewState}
    end.

terminate(_, State) ->
    {ok, State}.

code_change(_, State, _) ->
    {ok, State}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(endgame, ?MODULE).
-define(pending, etorrent_pending).
-define(chunkstate, etorrent_chunkstate).

testid() -> 0.
testpid() -> ?endgame:lookup_server(testid()).

setup() ->
    {ok, PPid} = ?pending:start_link(testid()),
    {ok, EPid} = ?endgame:start_link(testid()),
    {PPid, EPid}.

teardown({PPid, EPid}) ->
    ok = etorrent_utils:shutdown(EPid),
    ok = etorrent_utils:shutdown(PPid).



endgame_test_() ->
    {setup, local,
        fun() -> application:start(gproc) end,
        fun(_) -> application:stop(gproc) end,
    {foreach, local,
        fun setup/0,
        fun teardown/1, [
    ?_test(test_registers()),
    ?_test(test_starts_inactive()),
    ?_test(test_activated())
    ]}}.

test_registers() ->
    ?assert(is_pid(?endgame:lookup_server(testid()))),
    ?assert(is_pid(?endgame:await_server(testid()))).

test_starts_inactive() ->
    ?assertNot(?endgame:is_active(testpid())).

test_activated() ->
    ?assertEqual(ok, ?endgame:activate(testpid())),
    ?assert(?endgame:is_active(testpid())).



-endif.
