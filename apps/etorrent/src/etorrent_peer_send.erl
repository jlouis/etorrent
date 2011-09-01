%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Handle outgoing messages to a peer
%% <p>This module handles all outgoing messaging for a peer. It
%% supports various API calls to facilitate this</p>
%% <p>Note that this module has two modes, <em>fast</em> and
%% <em>slow</em>. The fast mode outsources the packet encoding to the
%% C-layer, whereas the slow mode doesn't. The price to pay is that we
%% have a worse granularity on the rate calculations, so we only shift
%% into the fast gear when we have a certain amount of traffic going on.</p>
%% <p>The shift fast to slow, or slow to fast, is synchronized with
%% the process {@link etorrent_peer_recv}, so if altering the code,
%% beware of that</p>
%% @end
-module(etorrent_peer_send).
-behaviour(gen_server).

-include("etorrent_rate.hrl").
-include("log.hrl").


-ignore_xref([{'start_link', 3}]).
%% Apart from standard gen_server things, the main idea of this module is
%% to serve as a mediator for the peer in the send direction. Precisely,
%% we have a message we can send to the process, for each of the possible
%% messages one can send to a peer.

%% other functions
-export([start_link/3]).

%% message functions
-export([request/2,
         piece/5,
         cancel/4,
         reject/4,
         choke/1,
         unchoke/1,
         have/2,
         not_interested/1,
         interested/1,
         extended_msg/1,
         bitfield/2]).

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

-ignore_xref({start_link, 5}).

-record(state, {
    socket = none                :: none | gen_tcp:socket(),
    requests                     :: queue(),
    fast_extension = false       :: boolean(),
    control_pid = none           :: none | pid(),
    rate                         :: etorrent_rate:rate(),
    choke = true                 :: boolean(),
    %% Are we interested in the peer?
    interested = false           :: boolean(),
    torrent_id                   :: integer()}).

-define(DEFAULT_KEEP_ALIVE_INTERVAL, 120*1000). % From proto. spec.
-define(MAX_REQUESTS, 1024). % Maximal number of requests a peer may make.

%%====================================================================

%% @doc Start the encoder process.
%% @end
-spec start_link(port(), integer(), boolean()) ->
    ignore | {ok, pid()} | {error, any()}.
start_link(Socket, TorrentId, FastExtension) ->
    gen_server:start_link(?MODULE,
                          [Socket, TorrentId, FastExtension], []).

%% @doc Register the local process as the encoder for a socket
-spec register_server(gen_tcp:socket()) -> true.
register_server(Socket) ->
    etorrent_utils:register(server_name(Socket)).

%% @doc Lookup the encoder process for a socket
-spec lookup_server(gen_tcp:socket()) -> pid().
lookup_server(Socket) ->
    etorrent_utils:lookup(server_name(Socket)).

%% @doc Wait for the encoder process for a socket to register
-spec await_server(gen_tcp:socket()) -> pid().
await_server(Socket) ->
    etorrent_utils:await(server_name(Socket)).

%% @private Server name for encoder process.
server_name(Socket) ->
    {etorrent, Socket, encoder}.


%% @doc send a REQUEST message to the remote peer.
%% @end
-spec request(pid(), {integer(), integer(), integer()}) -> ok.
request(Pid, {Index, Offset, Size}) ->
    forward_message(Pid, {request, {Index, Offset, Size}}).


%% @doc send a PIECE message to the remote peer.
%% @end
-spec piece(pid(), integer(), integer(), integer(), binary()) -> ok.
piece(Pid, Index, Offset, Length, Data) when Length =:= byte_size(Data) ->
    forward_message(Pid, {piece, Index, Offset, Data}).


%% @doc Send a CANCEL message to the remote peer.
%% @end
-spec cancel(pid(), integer(), integer(), integer()) -> ok.
cancel(Pid, Index, Offset, Len) ->
    forward_message(Pid, {cancel, Index, Offset, Len}).


%% @doc Send a REJECT message to the remote peer.
%% @end
-spec reject(pid(), integer(), integer(), integer()) -> ok.
reject(Pid, Index, Offset, Length) ->
    forward_message(Pid, {reject_request, Index, Offset, Length}).


%% @doc CHOKE the peer.
%% @end
-spec choke(pid()) -> ok.
choke(Pid) ->
    forward_message(Pid, choke).


%% @doc UNCHOKE the peer.
%% end
-spec unchoke(pid()) -> ok.
unchoke(Pid) ->
    forward_message(Pid, unchoke).


%% @doc send a NOT_INTERESTED message
%% @end
-spec not_interested(pid()) -> ok.
not_interested(Pid) ->
    forward_message(Pid, not_interested).


%% @doc send an INTERESTED message
%% @end
-spec interested(pid()) -> ok.
interested(Pid) ->
    forward_message(Pid, interested).


%% @doc send a HAVE message
%% @end
-spec have(pid(), integer()) -> ok.
have(Pid, Piece) ->
    forward_message(Pid, {have, Piece}).


%% @doc Send a BITFIELD message to the peer
%% @end
-spec bitfield(pid(), binary()) -> ok. %% This should be checked
bitfield(Pid, BitField) ->
    forward_message(Pid, {bitfield, BitField}).


%% @doc Send off the default EXT_MSG to the peer
%% <p>This is part of BEP-10</p>
%% @end
-spec extended_msg(pid()) -> ok.
extended_msg(Pid) ->
    forward_message(Pid, {extended, 0, etorrent_proto_wire:extended_msg_contents()}).


%% @private Send a message to the encoder process.
%% The encoder process is expected to forward the message to the remote peer.
forward_message(Pid, Message) ->
    gen_server:cast(Pid, {forward, Message}).





%%====================================================================


%% @private
init([Socket, TorrentId, FastExtension]) ->
    erlang:send_after(?DEFAULT_KEEP_ALIVE_INTERVAL, self(), tick),
    erlang:send_after(?RATE_UPDATE, self(), rate_update),
    register_server(Socket),
    CPid = etorrent_peer_control:await_server(Socket),
    {ok, #state{socket = Socket,
		requests = queue:new(),
		rate = etorrent_rate:init(),
		control_pid = CPid,
		torrent_id = TorrentId,
		fast_extension = FastExtension}}.

%% @private
handle_call(Msg, _From, State) ->
    {stop, Msg, State}.



%% Regular messages. We just send them onwards on the wire.
handle_cast({forward, Message}, State) ->
    send_message(Message, State);

handle_cast(Msg, State) ->
    {stop, Msg, State}.


%% Whenever a tick is hit, we send out a keep alive message on the line.
%% @private
handle_info(tick, S) ->
    erlang:send_after(?DEFAULT_KEEP_ALIVE_INTERVAL, self(), tick),
    send_message(keep_alive, S, 0);

%% When we are requested to update our rate, we do it here.
handle_info(rate_update, S) ->
    erlang:send_after(?RATE_UPDATE, self(), rate_update),
    Rate = etorrent_rate:update(S#state.rate, 0),
    ok = etorrent_peer_states:set_send_rate(S#state.torrent_id,
					    S#state.control_pid,
					    Rate#peer_rate.rate),
    {noreply, S#state { rate = Rate }};

%% Different timeouts.
%% When we are choking the peer and the piece cache is empty, garbage_collect() to reclaim
%% space quickly rather than waiting for it to happen.
%% @todo Consider if this can be simplified. It looks wrong here.
handle_info(timeout, #state { choke = true} = S) ->
    {noreply, S};
handle_info(timeout, #state { choke = false, requests = Reqs} = S) ->
    case queue:out(Reqs) of
        {empty, _} ->
            {noreply, S};
        {{value, {Index, Offset, Len}}, NewQ} ->
            send_piece(Index, Offset, Len, S#state { requests = NewQ } )
    end;
handle_info(Msg, S) ->
    ?WARN([got_unknown_message, Msg, S]),
    {stop, {unknown_msg, Msg}}.


%% @private
terminate(_Reason, _S) ->
    ok.


%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Send off a piece message
send_piece(Index, Offset, Len, S) ->
    {ok, PieceData} =
        etorrent_io:read_chunk(S#state.torrent_id, Index, Offset, Len),
    Msg = {piece, Index, Offset, PieceData},
    ok = etorrent_torrent:statechange(S#state.torrent_id,
                                        [{add_upload, Len}]),
    send_message(Msg, S).

send_message(Msg, S) ->
    send_message(Msg, S, 0).

%% @todo: Think about the stop messages here. They are definitely wrong.
send_message(Msg, S, Timeout) ->
    case send(Msg, S) of
        {ok, NS} -> {noreply, NS, Timeout};
        {error, closed, NS} -> {stop, normal, NS};
        {error, ebadf, NS} -> {stop, normal, NS}
    end.

send(Msg, #state { torrent_id = Id} = S) ->
    case etorrent_proto_wire:send_msg(S#state.socket, Msg) of
        {ok, Sz} ->
            NR = etorrent_rate:update(S#state.rate, Sz),
            ok = etorrent_torrent:statechange(Id, [{add_upload, Sz}]),
            ok = etorrent_rlimit:send(Sz),
            {ok, S#state { rate = NR}};
        {{error, E}, _Amount} ->
            {error, E, S}
    end.

