%%%-------------------------------------------------------------------
%%% File    : etorrent_rate_mgr.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Rate management process
%%%
%%% Created : 17 Jul 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------
-module(etorrent_rate_mgr).

-include("peer_state.hrl").
-include("rate_mgr.hrl").
-include("etorrent_rate.hrl").

-behaviour(gen_server).

-define(DEFAULT_SNUB_TIME, 30).

%% API
-export([start_link/0,

         choke/2, unchoke/2, interested/2, not_interested/2,
         local_choke/2, local_unchoke/2,

         recv_rate/4, send_rate/3,

         get_state/2,
         get_torrent_rate/2,

         fetch_recv_rate/2,
         fetch_send_rate/2,
         select_state/2,

         global_rate/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, { recv,
                 send,
                 state,

                 global_recv,
                 global_send}).

-define(SERVER, ?MODULE).

%% ====================================================================
-spec start_link() -> ignore | {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Send state information
-spec choke(integer(), pid()) -> ok.
choke(Id, Pid) -> gen_server:cast(?SERVER, {choke, Id, Pid}).

-spec unchoke(integer(), pid()) -> ok.
unchoke(Id, Pid) -> gen_server:cast(?SERVER, {unchoke, Id, Pid}).

-spec interested(integer(), pid()) -> ok.
interested(Id, Pid) -> gen_server:cast(?SERVER, {interested, Id, Pid}).

-spec not_interested(integer(), pid()) -> ok.
not_interested(Id, Pid) -> gen_server:cast(?SERVER, {not_interested, Id, Pid}).

-spec local_choke(integer(), pid()) -> ok.
local_choke(Id, Pid) -> gen_server:cast(?SERVER, {local_choke, Id, Pid}).

-spec local_unchoke(integer(), pid()) -> ok.
local_unchoke(Id, Pid) -> gen_server:cast(?SERVER, {local_unchoke, Id, Pid}).

-spec get_state(integer(), pid()) -> {value, boolean(), #peer_state{}}.
get_state(Id, Who) ->
    P = case ets:lookup(etorrent_peer_state, {Id, Who}) of
            [] -> #peer_state{}; % Pick defaults
            [Ps] -> Ps
        end,
    Snubbed = case ets:lookup(etorrent_recv_state, {Id, Who}) of
                [] -> false;
                [#rate_mgr { snub_state = normal}] -> false;
                [#rate_mgr { snub_state = snubbed}] -> true
              end,
    {value, Snubbed, P}.

-spec select_state(integer(), pid()) -> {value, #peer_state{}}.
select_state(Id, Who) ->
    case ets:lookup(etorrent_peer_state, {Id, Who}) of
        [] -> {value, #peer_state { }}; % Pick defaults
        [P] -> {value, P}
    end.

-spec fetch_recv_rate(integer(), pid()) ->
    none | undefined | float().
fetch_recv_rate(Id, Pid) -> fetch_rate(etorrent_recv_state, Id, Pid).

-spec fetch_send_rate(integer(), pid()) ->
    none | undefined | float().
fetch_send_rate(Id, Pid) -> fetch_rate(etorrent_send_state, Id, Pid).

-spec recv_rate(integer(), pid(), float(), normal | snubbed) -> ok.
recv_rate(Id, Pid, Rate, SnubState) ->
    gen_server:cast(?SERVER, {recv_rate, Id, Pid, Rate, SnubState}).

-spec get_torrent_rate(integer(), leeching | seeding) -> {ok, float()}.
get_torrent_rate(Id, Direction) ->
    gen_server:call(?SERVER, {get_torrent_rate, Id, Direction}).

-spec send_rate(integer(), pid(), float()) -> ok.
send_rate(Id, Pid, Rate) ->
    gen_server:cast(?SERVER, {send_rate, Id, Pid, Rate, unchanged}).

-spec global_rate() -> {float(), float()}.
global_rate() ->
    gen_server:call(?SERVER, global_rate).

%% ====================================================================

init([]) ->
    RTid = ets:new(etorrent_recv_state, [protected, named_table,
                                         {keypos, #rate_mgr.pid}]),
    STid = ets:new(etorrent_send_state, [protected, named_table,
                                         {keypos, #rate_mgr.pid}]),
    StTid = ets:new(etorrent_peer_state, [protected, named_table,
                                         {keypos, #peer_state.pid}]),
    {ok, #state{ recv = RTid, send = STid, state = StTid,
                 global_recv = etorrent_rate:init(?RATE_FUDGE),
                 global_send = etorrent_rate:init(?RATE_FUDGE)}}.

% @todo Lift these calls out of the process.
handle_call(global_rate, _From, S) ->
    RR = sum_global_rate(etorrent_recv_state),
    SR = sum_global_rate(etorrent_send_state),
    {reply, {RR, SR}, S};
handle_call({get_torrent_rate, Id, Direction}, _F, S) ->
    Tab = case Direction of
            leeching -> etorrent_recv_state;
            seeding  -> etorrent_send_state
          end,
    Objects = ets:match_object(Tab, #rate_mgr { pid = {Id, '_'}, _ = '_' }),
    R = lists:sum([K#rate_mgr.rate || K <- Objects]),
    {reply, {ok, R}, S};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast({What, Id, Pid}, S) ->
    ok = alter_state(What, Id, Pid),
    {noreply, S};
handle_cast({What, Id, Who, Rate, SnubState}, S) ->
    ok = alter_state(What, Id, Who, Rate, SnubState),
    {noreply, S};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, S) ->
    true = ets:match_delete(etorrent_recv_state, #rate_mgr { pid = {'_', Pid}, _='_'}),
    true = ets:match_delete(etorrent_send_state, #rate_mgr { pid = {'_', Pid}, _='_'}),
    true = ets:match_delete(etorrent_peer_state, #peer_state { pid = {'_', Pid}, _='_'}),
    {noreply, S};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _S) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% --------------------------------------------------------------------
sum_global_rate(Table) ->
    Objs = ets:match_object(Table, #rate_mgr { _ = '_' }),
    lists:sum([K#rate_mgr.rate || K <- Objs]).

alter_state(What, Id, Pid) ->
    _R = case ets:lookup(etorrent_peer_state, {Id, Pid}) of
        [] ->
            ets:insert(etorrent_peer_state,
              alter_record(What,
                           #peer_state { pid = {Id, Pid},
                                         choke_state = choked,
                                         interest_state = not_interested,
                                         local_choke = true})),
            erlang:monitor(process, Pid);
        [R] ->
            ets:insert(etorrent_peer_state,
                       alter_record(What, R))
    end,
    ok.

alter_record(What, R) ->
    case What of
        choke ->
            R#peer_state { choke_state = choked };
        unchoke ->
            R#peer_state { choke_state = unchoked };
        interested ->
            R#peer_state { interest_state = interested };
        not_interested ->
            R#peer_state { interest_state = not_interested };
        local_choke ->
            R#peer_state { local_choke = true };
        local_unchoke ->
            R#peer_state { local_choke = false}
    end.

alter_state(What, Id, Who, Rate, SnubState) ->
    T = case What of
            recv_rate -> etorrent_recv_state;
            send_rate -> etorrent_send_state
        end,
    _R = case ets:lookup(T, {Id, Who}) of
        [] ->
            ets:insert(T,
              #rate_mgr { pid = {Id, Who},
                          snub_state = case SnubState of
                                         snubbed -> snubbed;
                                         normal  -> normal;
                                         unchanged -> normal
                                       end,
                          rate = Rate }),
            erlang:monitor(process, Who);
        [R] ->
            ets:insert(T, R#rate_mgr { rate = Rate,
                                       snub_state =
                                            case SnubState of
                                              unchanged -> R#rate_mgr.snub_state;
                                              X         -> X
                                            end })
    end,
    ok.

-type rate_mgr_tables() :: etorrent_send_state | etorrent_recv_state.
-spec fetch_rate(rate_mgr_tables(), integer(), pid()) ->
    none | float() | undefined.
fetch_rate(Where, Id, Pid) ->
    case ets:lookup(Where, {Id, Pid}) of
        [] ->
            none;
        [R] -> R#rate_mgr.rate
    end.

