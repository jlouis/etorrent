%%%-------------------------------------------------------------------
%%% File    : etorrent_choker.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% License : See COPYING
%%% Description : Master process for a number of peers.
%%%
%%% Created : 18 Jul 2007 by
%%%      Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_choker).

-behaviour(gen_server).

-include("rate_mgr.hrl").
-include("peer_state.hrl").
-include("log.hrl").

%% API
-export([start_link/1, perform_rechoke/0, monitor/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {our_peer_id = none,
                info_hash = none,

                round = 0,

                optimistic_unchoke_pid = none,
                opt_unchoke_chain = []}).

-record(rechoke_info, {pid :: pid(),
                       kind :: 'seeding' | 'leeching',
                       state :: 'seeding' | 'leeching' ,
                       snubbed :: boolean(),
                       r_interest_state :: 'interested' | 'not_interested',
                       r_choke_state :: 'choked' | 'unchoked' ,
                       l_choke :: boolean(),
                       rate :: float() }).

-define(SERVER, ?MODULE).

-define(ROUND_TIME, 10000).
-define(DEFAULT_OPTIMISTIC_SLOTS, 1).

-ignore_xref([{start_link, 1}]).

%%====================================================================
%% API
%%====================================================================
-spec start_link(pid()) -> {ok, pid()} | {error, any()} | ignore.
start_link(OurPeerId) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [OurPeerId], []).

-spec perform_rechoke() -> ok.
perform_rechoke() ->
    gen_server:cast(?SERVER, rechoke).

-spec monitor(pid()) -> ok.
monitor(Pid) ->
    gen_server:call(?SERVER, {monitor, Pid}).

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: rechoke(State) -> ok
%% Description: Recalculate the choke/unchoke state of peers
%%--------------------------------------------------------------------
rechoke(S) ->
    Peers = build_rechoke_info(S#state.opt_unchoke_chain),
    {PreferredDown, PreferredSeed} = split_preferred(Peers),
    PreferredSet = prune_preferred_peers(PreferredDown, PreferredSeed),
    ToChoke = rechoke_unchoke(Peers, PreferredSet),
    rechoke_choke(ToChoke, 0, optimistics(PreferredSet)).

build_rechoke_info(Peers) ->
    {value, Seeding} = etorrent_torrent:seeding(),
    SeederSet = sets:from_list(Seeding),
    build_rechoke_info(SeederSet, Peers).

-spec lookup_info(set(), integer(), pid()) -> none | {seeding, float()}
                                                   | {leeching, float()}.
lookup_info(Seeding, Id, Pid) ->
    case sets:is_element(Id, Seeding) of
        true ->
            case etorrent_rate_mgr:fetch_send_rate(Id, Pid) of
                none -> none;
                Rate -> {seeding, Rate}
            end;
        false ->
            case etorrent_rate_mgr:fetch_recv_rate(Id, Pid) of
                none -> none;
                Rate -> {leeching, -Rate}
            end
    end.

build_rechoke_info(_Seeding, []) ->
    [];
build_rechoke_info(Seeding, [Pid | Next]) ->
    case etorrent_peer:find(Pid) of
        not_found -> build_rechoke_info(Seeding, Next);
        {peer_info, Kind, Id} ->
            {value, Snubbed, PeerState} = etorrent_rate_mgr:get_state(Id, Pid),
            case lookup_info(Seeding, Id, Pid) of
                none -> build_rechoke_info(Seeding, Next);
                {S, R} -> [#rechoke_info {
                                    pid = Pid,
                                    kind = Kind,
                                    state = S,
                                    rate = R,
                                    r_interest_state = PeerState#peer_state.interest_state,
                                    r_choke_state    = PeerState#peer_state.choke_state,
                                    l_choke          = PeerState#peer_state.local_choke,
                                    snubbed = Snubbed } |
                            build_rechoke_info(Seeding, Next)]
            end
    end.

advance_optimistic_unchoke(S) ->
    NewChain = move_cyclic_chain(S#state.opt_unchoke_chain),
    case NewChain of
        [] ->
            {ok, S}; %% No peers yet
        [H | _T] ->
            etorrent_peer_control:unchoke(H),
            {ok, S#state { opt_unchoke_chain = NewChain,
                           optimistic_unchoke_pid = H }}
    end.

move_cyclic_chain([]) -> [];
move_cyclic_chain(Chain) ->
    F = fun (Pid) ->
                case etorrent_peer:find(Pid) of
                    not_found -> true;
                    {peer_info, _Kind, Id} ->
                        {value, T} = etorrent_rate_mgr:select_state(Id, Pid),
                            not (T#peer_state.interest_state =:= interested
                                 andalso T#peer_state.choke_state =:= choked)
                end
        end,
    {Front, Back} = lists:splitwith(F, Chain),
    %% Advance chain
    Back ++ Front.

insert_new_peer_into_chain(Pid, Chain) ->
    Length = length(Chain),
    Index = lists:max([0, crypto:rand_uniform(0, Length)]),
    {Front, Back} = lists:split(Index, Chain),
    Front ++ [Pid | Back].

upload_slots() ->
    case application:get_env(etorrent, max_upload_slots) of
        {ok, auto} ->
            {ok, Rate} = application:get_env(etorrent, max_upload_rate),
            case Rate of
                N when N =<  0 -> 7; %% Educated guess
                N when N  <  9 -> 2;
                N when N  < 15 -> 3;
                N when N  < 42 -> 4;
                N ->
                    round(math:sqrt(N * 0.6))
            end;
        {ok, N} when is_integer(N) ->
            N
    end.

split_preferred(Peers) ->
    {Downs, Leechs} = split_preferred_peers(Peers, [], []),
    {lists:keysort(#rechoke_info.rate, Downs),
     lists:keysort(#rechoke_info.rate, Leechs)}.

prune_preferred_peers(SDowns, SLeechs) ->
    MaxUploads = upload_slots(),
    DUploads = lists:max([1, round(MaxUploads * 0.7)]),
    SUploads = lists:max([1, round(MaxUploads * 0.3)]),
    {SUP2, DUP2} =
        case lists:max([0, DUploads - length(SDowns)]) of
            0 -> {SUploads, DUploads};
            N -> {SUploads + N, DUploads - N}
        end,
    {SUP3, DUP3} =
        case lists:max([0, SUP2 - length(SLeechs)]) of
            0 -> {SUP2, DUP2};
            K ->
                {SUP2 - K, lists:min([DUP2 + K, length(SDowns)])}
        end,
    {TSDowns, TSLeechs} = {lists:sublist(SDowns, DUP3),
                           lists:sublist(SLeechs, SUP3)},
    sets:union(sets:from_list(TSDowns), sets:from_list(TSLeechs)).

rechoke_unchoke([], _PS) ->
    [];
rechoke_unchoke([P | Next], PSet) ->
    case sets:is_element(P, PSet) of
        true ->
            etorrent_peer_control:unchoke(P#rechoke_info.pid),
            rechoke_unchoke(Next, PSet);
        false ->
            [P | rechoke_unchoke(Next, PSet)]
    end.

optimistics(PSet) ->
    MinUp = case application:get_env(etorrent, min_uploads) of
                {ok, N} -> N;
                undefined -> ?DEFAULT_OPTIMISTIC_SLOTS
            end,
    lists:max([MinUp, upload_slots() - sets:size(PSet)]).

rechoke_choke([], _Count, _Optimistics) ->
    ok;
rechoke_choke([P | Next], Count, Optimistics) when Count >= Optimistics ->
    etorrent_peer_control:choke(P#rechoke_info.pid),
    rechoke_choke(Next, Count, Optimistics);
rechoke_choke([P | Next], Count, Optimistics) ->
    case P#rechoke_info.kind =:= seeding of
        true ->
            etorrent_peer_control:choke(P#rechoke_info.pid),
            rechoke_choke(Next, Count, Optimistics);
        false ->
            etorrent_peer_control:unchoke(P#rechoke_info.pid),
            case P#rechoke_info.r_interest_state =:= interested of
                true ->
                    rechoke_choke(Next, Count+1, Optimistics);
                false ->
                    rechoke_choke(Next, Count, Optimistics)
            end
    end.

split_preferred_peers([], Downs, Leechs) ->
    {Downs, Leechs};
split_preferred_peers([P | Next], Downs, Leechs) ->
    case P#rechoke_info.kind =:= seeding
          orelse P#rechoke_info.r_interest_state =:= not_interested of
        true ->
            split_preferred_peers(Next, Downs, Leechs);
        false when P#rechoke_info.state =:= seeding ->
            split_preferred_peers(Next, Downs, [P | Leechs]);
        false when P#rechoke_info.snubbed =:= true ->
            split_preferred_peers(Next, Downs, Leechs);
        false ->
            split_preferred_peers(Next, [P | Downs], Leechs)
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([OurPeerId]) ->
    erlang:send_after(?ROUND_TIME, self(), round_tick),
    {ok, #state{ our_peer_id = OurPeerId }}.

handle_call({monitor, Pid}, _From, S) ->
    _Tref = erlang:monitor(process, Pid),
    NewChain = insert_new_peer_into_chain(Pid, S#state.opt_unchoke_chain),
    perform_rechoke(),
    {reply, ok, S#state { opt_unchoke_chain = NewChain }};
handle_call(Request, _From, State) ->
    ?ERR([unknown_peer_group_call, Request]),
    Reply = ok,
    {reply, Reply, State}.
handle_cast(rechoke, S) ->
    rechoke(S),
    {noreply, S};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(round_tick, S) ->
    R = case S#state.round of
        0 ->
            {ok, NS} = advance_optimistic_unchoke(S),
            rechoke(NS),
            {noreply, NS#state { round = 2}};
        N when is_integer(N) ->
            rechoke(S),
            {noreply, S#state{round = S#state.round - 1}}
    end,
    erlang:send_after(?ROUND_TIME, self(), round_tick),
    R;
handle_info({'DOWN', _Ref, process, Pid, Reason}, S)
  when (Reason =:= normal) or (Reason =:= shutdown) ->
    % The peer shut down normally. Hence we just remove him and start up
    %  other peers. Eventually the tracker will re-add him to the peer list

    % XXX: We might have to do something else
    rechoke(S),

    NewChain = lists:delete(Pid, S#state.opt_unchoke_chain),
    {noreply, S#state { opt_unchoke_chain = NewChain }};
handle_info({'DOWN', _Ref, process, Pid, _Reason}, S) ->
    % The peer shut down unexpectedly re-add him to the queue in the *back*
    case etorrent_peer:select(Pid) of
        [_Peer] -> ok = rechoke(S);
             [] -> ok
    end,

    NewChain = lists:delete(Pid, S#state.opt_unchoke_chain),
    {noreply, S#state{opt_unchoke_chain = NewChain}};
handle_info(Info, State) ->
    ?ERR([unknown_info_peer_group, Info]),
    {noreply, State}.

terminate(_Reason, _S) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

