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

%% exported functions
-export([start_link/2]).

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


-record(state, {
    id            :: integer(), %% TorrentID
    socket        :: gen_tcp:socket(),
    packet = none :: etorrent_proto_wire:continuation(),
    rate          :: etorrent_rate:rate(),
    controller    :: pid(),
    last_piece_msg_count = 0 :: integer()}).

% Set the threshold to be 30 seconds by dividing the count with the rate update
% interval
-define(LAST_PIECE_COUNT_THRESHOLD, ((30*1000) / (?RATE_UPDATE))).

%% =======================================================================

%% @doc Start the gen_server process
%% @end
-spec start_link(integer(), any()) -> ignore | {ok, pid()} | {error, any()}.
start_link(TorrentId, Socket) ->
    gen_server:start_link(?MODULE, [TorrentId, Socket], []).


%% @doc Register the local process as the decoder for a socket
-spec register_server(gen_tcp:socket()) -> true.
register_server(Socket) ->
    etorrent_utils:register(server_name(Socket)).


%% @doc Lookup the decoding process for a socket
-spec lookup_server(gen_tcp:socket()) -> pid().
lookup_server(Socket) ->
    etorrent_utils:lookup(server_name(Socket)).


%% @doc Wait for the decoding process for a socket to register
-spec await_server(gen_tcp:socket()) -> pid().
await_server(Socket) ->
    etorrent_utils:await(server_name(Socket)).


%% @private Server name of decoder process.
server_name(Socket) ->
    {etorrent, Socket, decoder}.




%% @private
init([TorrentId, Socket]) ->
    register_server(Socket),
    ok = inet:setopts(Socket, [{active, false}]),
    CPid = etorrent_peer_control:await_server(Socket),
    erlang:send_after(?RATE_UPDATE, self(), rate_update),
    etorrent_rlimit:recv(1),
    State = #state{
        socket = Socket,
        rate = etorrent_rate:init(?RATE_FUDGE),
        id = TorrentId,
        controller = CPid},
    {ok, State}.


%% @private
handle_call(Msg, _, State) ->
    {stop, Msg, State}.


%% @private
handle_cast(Msg, State) ->
    {stop, Msg, State}.


%% @private
handle_info({rlimit, continue}, State) ->
    #state{socket=Socket} = State,
    case gen_tcp:recv(Socket, 0) of
        {error, closed} ->
            {stop, normal, State};
        {error, ebadf} ->
            {stop, normal, State};
        {error, einval} ->
            {stop, normal, State};
        {error, ehostunreach} ->
            {stop, normal, State};
        {error, etimedout} ->
            {stop, normal, State};
        {ok, Packet} ->
            PacketSize = byte_size(Packet),
            etorrent_rlimit:recv(PacketSize),
	        NewState = handle_packet(Packet, State),
	        {noreply, NewState}
    end;

handle_info(rate_update, State) ->
    #state{id=TorrentID, rate=Rate, last_piece_msg_count=PieceCount} = State,
    NewRate = etorrent_rate:update(Rate, 0),
    erlang:send_after(?RATE_UPDATE, self(), rate_update),
    SnubState = is_snubbing_us(State),
    ok = etorrent_peer_states:set_recv_rate(
            TorrentID, self(), NewRate#peer_rate.rate, SnubState),
    NewState = State#state{rate=NewRate, last_piece_msg_count=PieceCount+1},
    {noreply, NewState};

handle_info({tcp_closed, _}, State) ->
    {stop, normal, State};

handle_info(Msg, State) ->
    {stop, Msg, State}.


%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @private
handle_packet(Packet, State) ->
    #state{id=TorrentID, packet=Continuation, rate=Rate} = State,
    case etorrent_proto_wire:incoming_packet(Continuation, Packet) of
        ok ->
            State;
        {ok, BinMsg, Rest} ->
            MsgSize = byte_size(BinMsg),
            Msg = etorrent_proto_wire:decode_msg(BinMsg),
            NewRate = etorrent_rate:update(Rate, MsgSize),
            ok = etorrent_torrent:statechange(TorrentID, [{add_downloaded, MsgSize}]),
            etorrent_peer_control:incoming_msg(State#state.controller, Msg),
            NewCount = case Msg of
                {piece, _, _, _} -> 0;
                _ -> State#state.last_piece_msg_count
            end,
            NewState = State#state{
                rate=NewRate, packet=none, last_piece_msg_count=NewCount},
            handle_packet(Rest, NewState);
        {partial, NewContinuation} ->
            State#state{packet={partial, NewContinuation}}
    end.


%% @private
is_snubbing_us(S) when S#state.last_piece_msg_count > ?LAST_PIECE_COUNT_THRESHOLD ->
    snubbed;
is_snubbing_us(_S) ->
    normal.
