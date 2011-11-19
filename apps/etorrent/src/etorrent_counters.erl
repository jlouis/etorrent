%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Global counters in etorrent
%% <p>This module is used for global counters in etorrent. It counts
%% some simple things, like identifiers for torrents and the like</p>
%% @end
-module(etorrent_counters).

-behaviour(gen_server).
-include("log.hrl").

%% API
-export([start_link/0, next/1, obtain_peer_slot/0, slots_left/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {}).
-define(SERVER, ?MODULE).

%%====================================================================

%% @doc Start the counter server.
%% @end
-spec start_link() -> ignore | {ok, pid()} | {error, any()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Obtain the next integer in the sequence Sequence.
%% @end
-spec next(atom()) -> integer().
next(Sequence) ->
    gen_server:call(?SERVER, {next, Sequence}).

%% @doc Obtain a peer slot to work with.
%%   <p>This function returns either 'ok' or 'full' if too many slots
%%      are in use</p>
%% @end
-spec obtain_peer_slot() -> ok | full.
obtain_peer_slot() ->
    gen_server:call(?SERVER, obtain_peer_slot).

%% @doc Return the number of slots there are left
%% @end
-spec slots_left() -> {value, integer()}.
slots_left() ->
    gen_server:call(?SERVER, slots_left).

%%====================================================================

%% @private
init([]) ->
    _Tid = ets:new(etorrent_counters, [named_table, protected]),
    ets:insert(etorrent_counters, [{torrent, 0},
                                   {path_map, 0},
                                   {peer_slots, 0}]),
    {ok, #state{}}.

%% @private
handle_call({next, Seq}, _From, S) ->
    N = ets:update_counter(etorrent_counters, Seq, 1),
    {reply, N, S};
handle_call(obtain_peer_slot, {Pid, _Tag}, S) ->
    [{peer_slots, K}] = ets:lookup(etorrent_counters, peer_slots),
    case K >= etorrent_config:max_peers() of
        true ->
            {reply, full, S};
        false ->
            _Ref = erlang:monitor(process, Pid),
            _N = ets:update_counter(etorrent_counters, peer_slots, 1),
            {reply, ok, S}
    end;
handle_call(slots_left, _From, S) ->
    [{peer_slots, K}] = ets:lookup(etorrent_counters, peer_slots),
    {reply, {value, etorrent_config:max_peers() - K}, S};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info({'DOWN', _Ref, process, _Pid, _Reason}, S) ->
    K = ets:update_counter(etorrent_counters, peer_slots, {2, -1, 0, 0}),
    if
        K >= 0 -> ok;
        true -> ?ERR([counter_negative, K])
    end,
    {noreply, S};
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
