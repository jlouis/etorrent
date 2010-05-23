-module(etorrent_peer_recv).
-behaviour(gen_server).

-include("etorrent_rate.hrl").

-export([start_link/3, cb_go_fast/1, cb_go_slow/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).
-ignore_xref([{start_link, 3}]).

-type(mode() :: 'transition' | 'fast' | 'slow' | 'fast_setup').

-record(state, { socket = none,
                 parent = parent,
                 packet_continuation = none,
                 rate = none,
                 id = none,
                 rate_timer = none,
                 controller = none,
                 % The MODE of the receiver. It is either a fast peer, in which
                 % case messaging is handled by the underlying erlang VM, or slow,
                 % in which we handle it ourselves to get fine-grained rate measurement.
                 %
                 % Note that there is also a transition state, fast_setup for transitioning
                 % from slow to fast.
                 mode = slow :: mode() }).

-define(ENTER_FAST, 16000).
-define(ENTER_SLOW, 4000).

%% =======================================================================

start_link(TorrentId, Socket, Parent) ->
    gen_server:start_link(?MODULE, [TorrentId, Socket, Parent], []).

cb_go_fast(P) ->
    gen_server:call(P, go_fast).

cb_go_slow(P) ->
    gen_server:call(P, go_slow).

%% =======================================================================

go_fast(S) ->
    {ok, P} = etorrent_peer_sup:get_pid(S#state.parent, sender),
    etorrent_peer_send:go_fast(P),
    S#state { mode = transition }.

go_slow(S) ->
    {ok, P} = etorrent_peer_sup:get_pid(S#state.parent, sender),
    etorrent_peer_send:go_slow(P),
    S#state { mode = transition }.

handle_packet(Packet, S) ->
    Msg = etorrent_proto_wire:decode_msg(Packet),
    NR = etorrent_rate:update(S#state.rate, byte_size(Packet)),
    ok = etorrent_rate_mgr:recv_rate(
        S#state.id,
        S#state.controller,
        NR#peer_rate.rate,
        byte_size(Packet),
        case Msg of
            {piece, _, _, _} -> last_update;
            _ -> normal
        end),
    etorrent_peer_control:incoming_msg(S#state.controller, Msg),
    {ok, S#state { rate = NR }}.

handle_packet_slow(S, Packet) ->
    Cont = S#state.packet_continuation,
    case etorrent_proto_wire:incoming_packet(Cont, Packet) of
        ok -> case S#state.mode of
                fast_setup ->
                    {ok, go_fast(S)};
                _Otherwise -> {ok, S}
              end;
        {ok, P, R} ->
            {ok, NS} = handle_packet(P, S),
            handle_packet_slow(NS#state { packet_continuation = none}, R);
        {partial, C} ->
            {ok, S#state { packet_continuation = {partial, C} }}
    end.

% Change to fast mode


% Request the next message to be processed
next_msg(S) when S#state.mode =:= transition ->
    {noreply, S};
next_msg(S) when S#state.mode =:= fast ->
    {noreply, S};
next_msg(S) when S#state.mode =:= slow ->
    {noreply, S, 0};
next_msg(S) when S#state.mode =:= fast_setup ->
    {noreply, S, 0}.

%% ======================================================================

terminate(_Reason, _S) ->
    ok.

handle_info(timeout, S) when S#state.controller =:= none ->
    %% Haven't started up yet
    {ok, ControlPid} = etorrent_peer_sup:get_pid(S#state.parent, control),
    {noreply, S#state { controller = ControlPid }};
handle_info(timeout, S) ->
    Length =
        case S#state.mode of
            fast -> error_logger:error_report([timeout_in_fast_mode]), 0;
            slow -> 0;
            fast_setup ->
                {val, L} = etorrent_proto_wire:remaining_bytes(S#state.packet_continuation),
                L
        end,
    case gen_tcp:recv(S#state.socket, Length) of
        {ok, Packet} -> {ok, NS} = handle_packet_slow(S, Packet),
                        next_msg(NS);
        {error, closed} -> {stop, normal, S};
        {error, ebadf} -> {stop, normal, S};
        {error, timeout} -> next_msg(S);
        {error, ehostunreach} -> {stop, normal, S};
        {error, etimedout} -> next_msg(S)
    end;
handle_info(rate_update, S) ->
    NR = etorrent_rate:update(S#state.rate, 0),
    ok = etorrent_rate_mgr:recv_rate(S#state.id,
                                     self(),
                                     NR#peer_rate.rate, 0),
    if
        NR#peer_rate.rate > ?ENTER_FAST andalso S#state.mode =:= slow ->
            next_msg(S#state { rate = NR , mode = fast_setup });
        NR#peer_rate.rate < ?ENTER_SLOW andalso S#state.mode =:= fast ->
            SS = go_slow(S),
            next_msg(SS#state { rate = NR });
        true ->
            next_msg(S#state { rate = NR })
    end;
handle_info({tcp, _P, Packet}, S) ->
    {ok, NS} = handle_packet(Packet, S),
    {noreply, NS};
handle_info({tcp_closed, _P}, S) ->
    error_logger:info_report(peer_closed_port),
    {stop, normal, S};
handle_info(Info, S) ->
    error_logger:error_report([unknown_msg, Info]),
    next_msg(S).

handle_cast(Msg, S) ->
    error_logger:error_report([unknown_msg, Msg]),
    next_msg(S).

handle_call(go_fast, _From, S) ->
    error_logger:info_report(going_fast),
    ok = inet:setopts(S#state.socket, [{active, true}, {packet, 4}, {packet_size, 256*1024}]),
    {reply, ok, S#state { mode = fast }};
handle_call(go_slow, _From, S) ->
    error_logger:info_report(going_slow),
    ok = inet:setopts(S#state.socket, [{active, false}]),
    {reply, ok, S#state { mode = slow }};
handle_call(_Request, _From, S) ->
    next_msg(S).


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

init([TorrentId, Socket, Parent]) ->
    {ok, TRef} = timer:send_interval(?RATE_UPDATE, self(), rate_update),
    {ok, #state { socket = Socket, parent = Parent,
                  rate = etorrent_rate:init(?RATE_FUDGE),
                  rate_timer = TRef,
                  id = TorrentId,
                  mode = slow
                }, 0}.

