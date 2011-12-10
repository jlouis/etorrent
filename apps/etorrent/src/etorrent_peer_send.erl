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

-record(state, {
    socket     :: inet:socket(),
    buffer     :: queue(),
    control    :: pid(),
    limiter    :: none | pid(),
    rate       :: etorrent_rate:rate(),
    torrent_id :: integer()}).


-define(DEFAULT_KEEP_ALIVE_INTERVAL, 120*1000). % From proto. spec.
-define(MAX_REQUESTS, 1024). % Maximal number of requests a peer may make.


%% @doc Start the encoder process.
%% @end
-spec start_link(port(), integer(), boolean()) ->
    ignore | {ok, pid()} | {error, any()}.
start_link(Socket, TorrentId, FastExtension) ->
    gen_server:start_link(?MODULE,
                          [Socket, TorrentId, FastExtension], []).

%% @doc Register the local process as the encoder for a socket
-spec register_server(inet:socket()) -> true.
register_server(Socket) ->
    etorrent_utils:register(server_name(Socket)).

%% @doc Lookup the encoder process for a socket
-spec lookup_server(inet:socket()) -> pid().
lookup_server(Socket) ->
    etorrent_utils:lookup(server_name(Socket)).

%% @doc Wait for the encoder process for a socket to register
-spec await_server(inet:socket()) -> pid().
await_server(Socket) ->
    etorrent_utils:await(server_name(Socket)).

%% @private Server name for encoder process.
server_name(Socket) ->
    {etorrent, Socket, encoder}.


%% @doc send a REQUEST message to the remote peer.
%% @end
-spec request(pid(), {integer(), integer(), integer()}) -> ok.
request(Pid, {Index, Offset, Size}) ->
    forward_message(Pid, {request, Index, Offset, Size}).


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


%% @private
init([Socket, TorrentId, _FastExtension]) ->
    register_server(Socket),
    erlang:send_after(?DEFAULT_KEEP_ALIVE_INTERVAL, self(), tick),
    erlang:send_after(?RATE_UPDATE, self(), rate_update),
    CPid = etorrent_peer_control:await_server(Socket),
    State = #state{
        socket = Socket,
		buffer = queue:new(),
		rate = etorrent_rate:init(),
		control = CPid,
        limiter = none,
		torrent_id = TorrentId},
    {ok, State}.


%% @private
handle_call(Msg, _From, State) ->
    {stop, Msg, State}.



%% @private Bittorrent messages. Push them into the buffer.
handle_cast({forward, Message}, State) ->
    #state{buffer=Buffer, limiter=Limiter} = State,
    case Limiter of
        none ->
            NewLimiter = etorrent_rlimit:send(1),
            NewBuffer = queue:in(Message, Buffer),
            NewState = State#state{buffer=NewBuffer, limiter=NewLimiter},
            {noreply, NewState};
        _ when is_pid(Limiter) ->
            NewBuffer = queue:in(Message, Buffer),
            NewState = State#state{buffer=NewBuffer},
            {noreply, NewState}
    end;

handle_cast(Msg, State) ->
    {stop, Msg, State}.


%% @private
%% Whenever a tick is hit, we send out a keep alive message on the line.
handle_info(tick, State) ->
    #state{torrent_id=TorrentID, rate=Rate, socket=Socket} = State,
    erlang:send_after(?DEFAULT_KEEP_ALIVE_INTERVAL, self(), tick),
    case send_message(TorrentID, keep_alive, Rate, Socket) of
        {ok, NewRate, _Size} ->
            NewState = State#state{rate=NewRate},
            {noreply, NewState};
        {stop, Reason} ->
            {stop, Reason, State}
    end;

%% When we are requested to update our rate, we do it here.
handle_info(rate_update, State) ->
    #state{torrent_id=TorrentID, rate=Rate, control=Control} = State,
    erlang:send_after(?RATE_UPDATE, self(), rate_update),
    NewRate = etorrent_rate:update(Rate, 0),
    ok = etorrent_peer_states:set_send_rate(TorrentID, Control, NewRate#peer_rate.rate),
    NewState = State#state{rate=NewRate},
    {noreply, NewState};

handle_info({rlimit, continue}, State) ->
    #state{torrent_id=TorrentID, rate=Rate, socket=Socket, buffer=Buffer} = State,
    case queue:is_empty(Buffer) of
        true ->
            NewState = State#state{limiter=none},
            {noreply, NewState};
        false ->
            Message = queue:head(Buffer),
            case send_message(TorrentID, Message, Rate, Socket) of
                {ok, NewRate, Size} ->
                    Limiter = etorrent_rlimit:send(Size),
                    NewBuffer = queue:tail(Buffer),
                    NewState = State#state{
                        rate=NewRate,
                        buffer=NewBuffer,
                        limiter=Limiter},
                    {noreply, NewState};
                {stop, Reason} ->
                    {stop, Reason, State}
            end
    end;

handle_info(Msg, State) ->
    {stop, Msg, State}.


%% @private
terminate(_Reason, _S) ->
    ok.


%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @todo: Think about the stop messages here. They are definitely wrong.
send_message(TorrentID, Message, Rate, Socket) ->
    case etorrent_proto_wire:send_msg(Socket, Message) of
        {ok, Size} ->
            ok = etorrent_torrent:statechange(TorrentID, [{add_upload, Size}]),
            {ok, etorrent_rate:update(Rate, Size), Size};
        {{error, closed}, _} ->
            {stop, normal};
        {{error, ebadf}, _} ->
            {stop, normal}
    end.
