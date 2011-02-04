%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Handle incoming messages from a peer
%% <p>This module is a gen_server process handling all incoming
%% messages from a peer. The intention is that this module decodes the
%% message and sends it on the to the {@link etorrent_peer_control}
%% process.</p>
%% <p>The module has two modes, fast and slow. In the fast mode, some
%% of the packet decoding is done in the Erlang VM, but the rate
%% granularity is somewhat lost. So we only enable fast mode when the
%% rate goes beyond a certain threshold, so we get accurate rate
%% measurement anyway. The change of mode is in synchronizatio with
%% the module {@link etorrent_peer_send}.</p>
%% @end
-module(etorrent_peer_recv).
-behaviour(gen_server).

-include("etorrent_rate.hrl").
-include("log.hrl").

-export([start_link/2, cb_go_fast/1, cb_go_slow/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).
-ignore_xref([{start_link, 2}]).

-type(mode() :: 'transition' | 'fast' | 'slow' | 'fast_setup').

-record(state, { socket                   :: gen_tcp:socket(),
                 packet_continuation =
		   none                   :: etorrent_proto_wire:continuation(),
                 rate                     :: etorrent_rate:rate(),
		 control_pid              :: pid(),
                 last_piece_msg_count = 0 :: integer(),
                 id                       :: integer(),
                 controller = none        :: none | pid(),
		 %% The MODE of the receiver. It is either a fast
                 %% peer, in which case messaging is handled by the
                 %% underlying erlang VM, or slow, % in which we
                 %% handle it ourselves to get fine-grained rate
                 %% measurement.  % Note that there is also a
                 %% transition state, fast_setup for transitioning %
                 %% from slow to fast.
                 mode = slow              :: mode() }).

-define(ENTER_FAST, 16000).
-define(ENTER_SLOW, 4000).
% Set the threshold to be 30 seconds by dividing the count with the rate update
% interval
-define(LAST_PIECE_COUNT_THRESHOLD, ((30*1000) / (?RATE_UPDATE))).

%% =======================================================================

%% @doc Start the gen_server process
%% @end
-spec start_link(integer(), any()) -> ignore | {ok, pid()} | {error, any()}.
start_link(TorrentId, Socket) ->
    gen_server:start_link(?MODULE, [TorrentId, Socket], []).

%% @doc Callback to go to fast mode.
%% <em>Only intended caller is {@link etorrent_peer_send}</em>
%% @end
-spec cb_go_fast(pid()) -> ok.
cb_go_fast(P) ->
    gen_server:call(P, go_fast).

%% @doc Callback to go to slow mode.
%% <em>Only intended caller is {@link etorrent_peer_send}</em>
%% @end
-spec cb_go_slow(pid()) -> ok.
cb_go_slow(P) ->
    gen_server:call(P, go_slow).

%% =======================================================================

go_fast(S) ->
    P = gproc:lookup_local_name({peer, S#state.socket, sender}),
    etorrent_peer_send:go_fast(P),
    S#state { mode = transition }.

go_slow(S) ->
    P = gproc:lookup_local_name({peer, S#state.socket, sender}),
    etorrent_peer_send:go_slow(P),
    S#state { mode = transition }.

handle_packet(Packet, #state { id = Id } = S) ->
    Msg = etorrent_proto_wire:decode_msg(Packet),
    NR = etorrent_rate:update(S#state.rate, byte_size(Packet)),
    ok = etorrent_torrent:statechange(Id, [{add_downloaded, byte_size(Packet)}]),
    etorrent_peer_control:incoming_msg(S#state.controller, Msg),
    NewCount = case Msg of {piece, _, _, _} -> 0;
                           _ -> S#state.last_piece_msg_count
               end,
    S#state { rate = NR, last_piece_msg_count = NewCount }.

handle_packet_slow(S, Packet) ->
    Cont = S#state.packet_continuation,
    case etorrent_proto_wire:incoming_packet(Cont, Packet) of
        ok -> case S#state.mode of
                fast_setup ->
                    go_fast(S);
                _Otherwise -> S
              end;
        {ok, P, R} ->
            NS = handle_packet(P, S),
            handle_packet_slow(NS#state { packet_continuation = none}, R);
        {partial, C} ->
            S#state { packet_continuation = {partial, C} }
    end.

% Request the next message to be processed
next_msg(Mode) ->
    case Mode of
        transition  -> infinity;
        fast        -> infinity;
        slow        -> 0;
        fast_setup  -> 0
    end.

is_snubbing_us(S) when S#state.last_piece_msg_count > ?LAST_PIECE_COUNT_THRESHOLD ->
    snubbed;
is_snubbing_us(_S) ->
    normal.

%% ======================================================================

%% @private
terminate(_Reason, _S) ->
    ok.

%% @private
handle_info(timeout,
	    #state { controller = none,
		     socket = Sock } = S) ->
    %% Haven't started up yet
    ControlPid = gproc:lookup_local_name({peer, Sock, control}),
    {noreply, S#state { controller = ControlPid }};
handle_info(timeout, S) ->
    Length =
        case S#state.mode of
            fast -> ?ERR([timeout_in_fast_mode]), 0;
            slow -> 0;
            fast_setup ->
                {val, L} = etorrent_proto_wire:remaining_bytes(S#state.packet_continuation),
                L
        end,
    Proceed = case gen_tcp:recv(S#state.socket, Length) of
		  {ok, Packet} -> {ok, Packet};
		  {error, closed} -> error;
		  {error, ebadf} -> error;
		  {error, einval} -> error;
		  {error, ehostunreach} -> error;
		  {error, etimedout} -> error
	      end,
    case Proceed of
        {ok, Pkt} ->
	    NS = handle_packet_slow(S, Pkt),
	    {noreply, NS, next_msg(NS#state.mode)};
        error -> {stop, normal, S}
    end;
handle_info(rate_update, OS) ->
    NR = etorrent_rate:update(OS#state.rate, 0),
    erlang:send_after(?RATE_UPDATE, self(), rate_update),
    SnubState = is_snubbing_us(OS),
    ok = etorrent_peer_states:set_recv_rate(OS#state.id,
					    self(),
					    NR#peer_rate.rate,
					    SnubState),
    S = OS#state { last_piece_msg_count = OS#state.last_piece_msg_count + 1 },
    SS = if
        NR#peer_rate.rate > ?ENTER_FAST andalso S#state.mode =:= slow ->
            S#state { rate = NR , mode = fast_setup };
        NR#peer_rate.rate < ?ENTER_SLOW andalso S#state.mode =:= fast ->
            NS = go_slow(S),
            NS#state { rate = NR };
        true ->
            S#state { rate = NR }
    end,
    {noreply, SS, next_msg(SS#state.mode)};
handle_info({tcp, _P, Packet}, S) ->
    NS = handle_packet(Packet, S),
    {noreply, NS};
handle_info({tcp_closed, _P}, S) ->
    {stop, normal, S};
handle_info(Info, S) ->
    ?WARN([unknown_handle_info, Info]),
    {noreply, S, next_msg(S#state.mode)}.

%% @private
handle_cast(Msg, S) ->
    ?WARN([unknown_handle_cast, Msg]),
    {noreply, S, next_msg(S#state.mode)}.

%% @private
handle_call(go_fast, _From, S) ->
    ok = inet:setopts(S#state.socket, [{active, true}, {packet, 4}, {packet_size, 256*1024}]),
    {reply, ok, S#state { mode = fast }};
handle_call(go_slow, _From, S) ->
    ok = inet:setopts(S#state.socket, [{active, false}]),
    {reply, ok, S#state { mode = slow }};
handle_call(Req, _From, S) ->
    ?WARN([unknown_handle_call, Req]),
    {noreply, S, next_msg(S#state.mode)}.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @private
init([TorrentId, Socket]) ->
    gproc:add_local_name({peer, Socket, receiver}),
    {CPid, _} = gproc:await({n,l,{peer, Socket, control}}),
    erlang:send_after(?RATE_UPDATE, self(), rate_update),
    {ok, #state { socket = Socket,
                  rate = etorrent_rate:init(?RATE_FUDGE),
                  id = TorrentId,
                  mode = slow,
		  control_pid = CPid
                }, 0}.

