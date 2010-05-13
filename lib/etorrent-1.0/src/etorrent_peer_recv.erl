-module(etorrent_peer_recv).
-behaviour(gen_server).

-include("etorrent_rate.hrl").

-export([start_link/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, { socket = none,
                 parent = parent,
                 packet_continuation = none,
                 rate = none,
                 id = none,
                 rate_timer = none,
                 controller = none }).

%%====================================================================
%% API
%%====================================================================

start_link(TorrentId, Socket, Parent) ->
    gen_server:start_link(?MODULE, [TorrentId, Socket, Parent], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([TorrentId, Socket, Parent]) ->
    process_flag(trap_exit, true),
    {ok, TRef} = timer:send_interval(?RATE_FUDGE, self(), rate_update),
    {ok, #state { socket = Socket, parent = Parent,
                  rate = etorrent_rate:init(?RATE_FUDGE),
                  rate_timer = TRef,
                  id = TorrentId
                }, 0}.

handle_info(timeout, S) when S#state.controller =:= none ->
    %% Haven't started up yet
    {ok, ControlPid} = etorrent_t_peer_sup:get_pid(S#state.parent, controller),
    {noreply, S#state { controller = ControlPid }};
handle_info(timeout, S) ->
    case gen_tcp:recv(S#state.socket, 0) of
        {ok, Packet} ->
            case handle_packet(S, Packet) of
                {ok, NS} -> {noreply, NS, 0};
                {error, Reason} ->
                    {stop, Reason, S}
            end;
        {error, closed} ->
            {stop, normal, S};
        {error, ebadf} ->
            {stop, normal, S};
        {error, ehostunreach} ->
            {stop, normal, S};
        {error, etimedout} ->
            {noreply, S, 0}
    end;
handle_info(_Info, State) ->
    {noreply, State, 0}.

handle_packet(S, Packet) ->
    Cont = S#state.packet_continuation,
    case etorrent_proto_wire:incoming_packet(Cont, Packet) of
        ok -> {ok, S};
        {ok, P, R} ->
            Msg = etorrent_proto_wire:decode_msg(P),
            NR = etorrent_rate:update(S#state.rate, size(P)),
            ok = etorrent_rate_mgr:recv_rate(
                S#state.id,
                self(),
                NR#peer_rate.rate,
                size(P),
                case Msg of
                    {piece, _, _, _} -> last_update;
                    _                -> normal end),
            etorrent_peer_control:incoming_msg(Msg),
            handle_packet(S#state { rate = NR,
                                    packet_continuation = none}, R);
        {partial, C} ->
            {ok, S#state { packet_continuation = {partial, C} }}
    end.

terminate(_Reason, S) ->
    timer:cancel(S#state.rate_timer),
    ok.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

handle_cast(_Msg, S) ->
    {noreply, S, 0}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State, 0}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

