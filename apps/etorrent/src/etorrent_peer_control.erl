%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Manage and control peer communication.
%% <p>This gen_server handles the communication with a single peer. It
%% handles incoming connections, and transmits the right messages back
%% to the peer, according to the specification of the BitTorrent
%% procotol.</p>
%% <p>Each peer runs one gen_server of this kind. It handles the
%% queueing of pieces, requestal of new chunks to download, choking
%% states, the remotes request queue, etc.</p>
%% @end
-module(etorrent_peer_control).

-behaviour(gen_server).

-include("etorrent_rate.hrl").
-include("log.hrl").

%% API
-export([start_link/7,
        choke/1,
        unchoke/1,
        initialize/2,
        incoming_msg/2,
        stop/1]).

%% gproc registry entries
-export([register_server/2,
         lookup_server/2,
         await_server/2,
         lookup_peers/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3,
         format_status/2]).

%% peer state notifications
-export([check_interest/2,
         recheck_interest/3,
         check_seeder/2]).

-type torrentid() :: etorrent_types:torrent_id().
-type pieceindex() :: etorrent_types:pieceindex().
-type peerstate() :: etorrent_peerstate:peerstate().
-type peerconf() :: etorrent_peerconf:peerconf().
-type tservices() :: etorrent_download:tservices().
-record(state, {
    torrent_id = exit(required) :: integer(),
    info_hash = exit(required) ::  binary(),
    socket = none  :: none | gen_tcp:socket(),
    send_pid :: pid(),

    download = exit(required) :: tservices(),
    rate :: etorrent_rate:rate(),

    remote_state  = exit(required) :: peerstate(),
    local_state   = exit(required) :: peerstate(),
    remote_config = exit(required) :: peerconf(),
    local_config  = exit(required) :: peerconf()}).


-define(DEFAULT_CHUNK_SIZE, 16384). % Default size for a chunk. All clients use this.
-define(HIGH_WATERMARK, 30). % How many chunks to queue up to
-define(LOW_WATERMARK, 5).  % Requeue when there are less than this number of pieces in queue

-ignore_xref([{start_link, 6}]).

%%====================================================================

%% @doc Register the current process as a peer process
register_server(TorrentID, PeerID) ->
    etorrent_utils:register(server_name(TorrentID, PeerID)),
    etorrent_utils:register_member(group_name(TorrentID)).

%% @doc Lookup the process id of a specific peer.
lookup_server(TorrentID, PeerID) ->
    etorrent_utils:lookup(server_name(TorrentID, PeerID)).

%% @doc
await_server(TorrentID, PeerID) ->
    etorrent_utils:await(server_name(TorrentID, PeerID)).

%% @doc
-spec lookup_peers(torrentid()) -> [pid()].
lookup_peers(TorrentID) ->
    etorrent_utils:lookup_members(group_name(TorrentID)).


%% @doc Name of a specific peer process
server_name(TorrentID, PeerID) ->
    {etorrent, TorrentID, peer, PeerID}.

%& @doc Name of all peers in a torrent
group_name(TorrentID) ->
    {etorrent, TorrentID, peers}.




%% @doc Starts the server
%% @end
start_link(TrackerUrl, LocalPeerId, InfoHash, Id, {IP, Port}, Caps, Socket)
  when is_binary(LocalPeerId) ->
    gen_server:start_link(?MODULE, [TrackerUrl, LocalPeerId, InfoHash,
                                    Id, {IP, Port}, Caps, Socket], []).

%% @doc Gracefully ask the server to stop.
%% @end
stop(Pid) ->
    gen_server:cast(Pid, stop).

%% @doc Choke the peer.
%% <p>The intended caller of this function is the {@link etorrent_choker}</p>
%% @end
choke(Pid) ->
    gen_server:cast(Pid, choke).

%% @doc Unchoke the peer.
%% <p>The intended caller of this function is the {@link etorrent_choker}</p>
%% @end
unchoke(Pid) ->
    gen_server:cast(Pid, unchoke).

%% @doc Initialize the connection.
%% <p>The `Way' parameter tells the client of the connection is
%% `incoming' or `outgoing'. They are handled differently since part
%% of the handshake is already completed for incoming connections.</p>
%% @end
-type direction() :: incoming | outgoing.
-spec initialize(pid(), direction()) -> ok.
initialize(Pid, Way) ->
    gen_server:cast(Pid, {initialize, Way}).


%% @doc Inject an incoming message to the process.
%% <p>This is the main "Handle-incoming-messages" call. The intended
%% caller is {@link etorrent_peer_recv}, whenever a message arrives on
%% the socket.</p>
%% @end
incoming_msg(Pid, Msg) ->
    gen_server:cast(Pid, {incoming_msg, Msg}).


%% @doc Check if a peer provided an interesting piece.
%% This function should be called when a have-message is received.
%% If the piece is interesting and we are not already interested a
%% status update is sent to the local process to trigger a state
%% change.
%% @end
-spec check_interest(pieceindex(), peerstate()) -> ok.
check_interest(Piece, LocalState) ->
    case etorrent_peerstate:interesting(Piece, LocalState) of
        unchanged -> ok;
        true  -> self() ! {peer, {interested, true}}, ok
    end.


%% @doc Check if a peer still provides interesting pieces.
%% This function should be called when a have-message is sent. If the
%% peer no longer provides any interesting pieces and we are interested
%% a status update is sent to the local process to trigger a state change.
%% @end
-spec recheck_interest(pieceindex(), peerstate(), peerstate()) -> ok.
recheck_interest(Piece, RemoteState, LocalState) ->
    case etorrent_peerstate:interesting(Piece, RemoteState, LocalState) of
        unchanged -> ok;
        true  -> self() ! {peer, {interested, true}}, ok;
        false -> self() ! {peer, {interested, false}}, ok
    end.


%% @doc Check if a peer has become a seeder
%% @end
-spec check_seeder(peerstate(), peerstate()) -> ok.
check_seeder(RemoteState, LocalState) ->
    case etorrent_peerstate:seeder(LocalState) of
        false -> ok;
        true  ->
            case etorrent_peerstate:seeder(RemoteState) of
                false -> ok;
                true  -> self() ! {peer, {seeder, true}}, ok
            end
    end.

%% @doc Check if the request queue is low
-spec poll_queue(tservices(), pid(), peerstate(), peerstate()) -> peerstate().
poll_queue(Download, SendPid, RemoteState, LocalState) ->
    case etorrent_peerstate:needreqs(LocalState) of
        false -> LocalState;
        true  ->
            Requests = etorrent_peerstate:requests(LocalState),
            Pieces = etorrent_peerstate:pieces(RemoteState),
            Needs = etorrent_rqueue:needs(Requests),
            case etorrent_download:request_chunks(Needs, Pieces, Download) of
                {ok, assigned} ->
                    LocalState;
                {ok, Chunks} ->
                    [etorrent_peer_send:local_request(SendPid, Chunk)
                    || Chunk <- Chunks],
                    NewRequests = etorrent_rqueue:push(Chunks, Requests),
                    etorrent_peerstate:requests(NewRequests, LocalState)
            end
    end.



%% @private
init([TrackerUrl, LocalPeerID, InfoHash, TorrentID, {IP, Port}, Caps, Socket]) ->
    %% Use socket handle as remote peer-id.
    register_server(TorrentID, Socket),
    random:seed(now()),

    %% Keep track of the local state and the remote state
    {value, Numpieces} = etorrent_torrent:num_pieces(TorrentID),
    LocalState  = etorrent_peerstate:new(Numpieces),
    RemoteState = etorrent_peerstate:new(Numpieces),

    Extended = proplists:get_bool(extended_messaging, Caps),
    LocalConf0 = etorrent_peerconf:new(),
    LocalConf1 = etorrent_peerconf:peerid(LocalPeerID, LocalConf0),
    LocalConf  = etorrent_peerconf:extended(Extended, LocalConf1),
    RemoteConf = etorrent_peerconf:new(),

    Download = etorrent_download:await_servers(TorrentID),

    ok = etorrent_table:new_peer(TrackerUrl, IP, Port, TorrentID, self(), leeching),
    ok = etorrent_choker:monitor(self()),
    State = #state{
        torrent_id=TorrentID,
        info_hash=InfoHash,
        socket=Socket,
        download=Download,
        remote_state=RemoteState,
        local_state=LocalState,
        remote_config=RemoteConf,
        local_config=LocalConf},
    {ok, State}.

%% @private
handle_cast({initialize, Way}, S) ->
    case etorrent_counters:obtain_peer_slot() of
        ok ->
            case connection_initialize(Way, S) of
                {ok, NS} -> {noreply, NS};
                {stop, Type} -> {stop, Type, S}
            end;
        full ->
            {stop, normal, S}
    end;
handle_cast({incoming_msg, Msg}, S) ->
    case handle_message(Msg, S) of
        {ok, NS} -> {noreply, NS};
        {stop, Reason, NS} -> {stop, Reason, NS}
    end;
handle_cast(choke, S) ->
    etorrent_peer_send:choke(S#state.send_pid),
    {noreply, S};

handle_cast(unchoke, S) ->
    etorrent_peer_send:unchoke(S#state.send_pid),
    {noreply, S};

handle_cast(interested, State) ->
    self() ! {interested, true},
    {noreply, State};

handle_cast(stop, S) ->
    {stop, normal, S};

handle_cast(Msg, State) ->
    ?WARN([unknown_msg, Msg]),
    {noreply, State}.


%% @private
handle_info({chunk, {fetched, Index, Offset, Length, _}}, State) ->
    #state{send_pid=SendPid, local_state=LocalState} = State,
    Requests = etorrent_peerstate:requests(LocalState),
    Hasrequest = etorrent_rqueue:member(Index, Offset, Length, Requests),
    NewLocalState = if
        not Hasrequest ->
            Requests;
        Hasrequest ->
            etorrent_peer_send:cancel(SendPid, Index, Offset, Length),
            NewReqs = etorrent_rqueue:delete(Index, Offset, Length, Requests),
            etorrent_peerstate:requests(NewReqs, LocalState)
    end,
    NewState = State#state{local_state=NewLocalState},
    {noreply, NewState};

handle_info({piece, {valid, Piece}}, State) ->
    #state{send_pid=SendPid, local_state=LocalState} = State,
    NewLocalState = etorrent_peerstate:hasone(Piece, LocalState),
    etorrent_peer_send:have(SendPid, Piece),
    NewState = State#state{local_state=NewLocalState},
    {noreply, NewState};

handle_info({piece, {unassigned, _}}, State) ->
    ok = etorrent_peerstate:check_queue(self()),
    %% etorrent_peerstate:interested(self()),
    {noreply, State};

handle_info({peer, {check, seeder}}, State) ->
    {noreply, State};


handle_info({download, Update}, State) ->
    #state{download=Download} = State,
    NewDownload = etorrent_download:update(Update, Download),
    NewState = State#state{download=NewDownload},
    {noreply, NewState};

handle_info({interest, Change}, State) ->
    #state{send_pid=SendPid, local_state=LocalState} = State,
    Current = etorrent_peerstate:interested(LocalState),
    NewLocalState = if
        Current == Change ->
            LocalState;
        Change == true ->
            ok = etorrent_peer_send:interested(SendPid),
            etorrent_peerstate:interested(true, LocalState);
        Change == false ->
            ok = etorrent_peer_send:not_interested(SendPid),
            etorrent_peerstate:interested(false, LocalState)
    end,
    NewState = State#state{local_state=NewLocalState},
    {noreply, NewState};
            
handle_info({tcp, _, _}, State) ->
    ?ERR([wrong_controller]),
    {noreply, State};

handle_info(Info, State) ->
    ?WARN([unknown_msg, Info]),
    {noreply, State}.

%% @private
terminate(_Reason, _S) ->
    ok.

%% @private
handle_call(Request, _From, State) ->
    ?WARN([unknown_handle_call, Request]),
    {noreply, State}.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

format_status(_Opt, [_Pdict, S]) ->
    #state{remote_config=RemoteConf} = S,
    RemoteID = etorrent_peerconf:peerid(RemoteConf),
    IPPort = case inet:peername(S#state.socket) of
        {ok, IPP} -> IPP;
        {error, Reason} -> {port_error, Reason}
    end,
    Term = [
        {torrent_id,     S#state.torrent_id},
        {remote_peer_id, RemoteID},
        {info_hash,      S#state.info_hash},
        {socket_info,    IPPort}],
    [{data,  [{"State",  Term}]}].
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Func: handle_message(Msg, State) -> {ok, NewState} | {stop, Reason, NewState}
%% Description: Process an incoming message Msg from the wire. Return either
%%  {ok, S} if the processing was ok, or {stop, Reason, S} in case of an error.
%%--------------------------------------------------------------------
-spec handle_message(_,_) -> {'ok',_} | {'stop', _, _}.
handle_message(keep_alive, S) ->
    {ok, S};
handle_message(choke, State) ->
    #state{
        torrent_id=TorrentID,
        local_state=LocalState,
        local_config=LocalConf,
        download=Download} = State,
    ok = etorrent_peer_states:set_choke(TorrentID, self()),
    Fast = etorrent_peerconf:fast(LocalConf),
    NewState = case Fast of
        true ->
            %% If the Fast Extension is enabled a CHOKE message does
            %% not imply that all outstanding requests are dropped.
            NewLocalState = etorrent_peerstate:choked(true, LocalState),
            State#state{local_state=NewLocalState};
        false ->
            %% A CHOKE message implies that all outstanding requests has been dropped.
            Requests = etorrent_peerstate:requests(LocalState),
            Pieces = etorrent_rqueue:pieces(Requests),
            Chunks = etorrent_rqueue:to_list(Requests),
            Peers  = etorrent_peer_control:lookup_peers(TorrentID),
            ok = etorrent_piecestate:unassigned(Pieces, Peers),
            ok = etorrent_download:chunks_dropped(Chunks, Download),
            NewReqs = etorrent_rqueue:flush(Requests),
            TmpLocalState = etorrent_peerstate:choked(true, LocalState),
            NewLocalState = etorrent_peerstate:requests(NewReqs, TmpLocalState),
            State#state{local_state=NewLocalState}
    end,
    {ok, NewState};

handle_message(unchoke, State) ->
    #state{
        torrent_id=TorrentID, send_pid=SendPid, download=Download,
        local_state=LocalState, remote_state=RemoteState} = State,
    ok = etorrent_peer_states:set_unchoke(TorrentID, self()),
    TmpLocalState = etorrent_peerstate:choked(false, LocalState),
    NewLocalState = poll_queue(Download, SendPid, RemoteState, TmpLocalState),
    NewState = State#state{local_state=NewLocalState},
    {ok, NewState};

handle_message(interested, State) ->
    #state{torrent_id=TorrentID, send_pid=SendPid, remote_state=RemoteState} = State,
    ok = etorrent_peer_states:set_interested(TorrentID, self()),
    ok = etorrent_peer_send:check_choke(SendPid),
    NewRemoteState = etorrent_peerstate:interested(true, RemoteState),
    NewState = State#state{remote_state=NewRemoteState},
    {ok, NewState};

handle_message(not_interested, State) ->
    #state{torrent_id=TorrentID, send_pid=SendPid, remote_state=RemoteState} = State,
    ok = etorrent_peer_states:set_not_interested(TorrentID, self()),
    ok = etorrent_peer_send:check_choke(SendPid),
    NewRemoteState = etorrent_peerstate:interested(false, RemoteState),
    NewState = State#state{remote_state=NewRemoteState},
    {ok, NewState};

handle_message({request, Index, Offset, Len}, S) ->
    etorrent_peer_send:remote_request(S#state.send_pid, Index, Offset, Len),
    {ok, S};

handle_message({cancel, Index, Offset, Len}, S) ->
    etorrent_peer_send:cancel(S#state.send_pid, Index, Offset, Len),
    {ok, S};

handle_message({have, Piece}, State) ->
    #state{torrent_id=TorrentID, remote_state=RemoteState, local_state=LocalState} = State,

    NewRemoteState = etorrent_peerconf:hasone(Piece, RemoteState),
    Pieceset = etorrent_peerstate:pieces(NewRemoteState),
    ok = etorrent_scarcity:add_piece(TorrentID, Piece, Pieceset),

    ok = etorrent_peer_control:check_interest(Piece, LocalState),
    ok = etorrent_peer_control:check_seeder(NewRemoteState, LocalState),

    NewState = State#state{remote_state=NewRemoteState},
    {ok, NewState};

handle_message({suggest, Piece}, State) ->
    #state{remote_config=RemoteConf} = State,
    PeerID = etorrent_peerconf:peerid(RemoteConf),
    ?INFO([{peer_id, PeerID}, {suggest, Piece}]),
    {ok, State};

handle_message(have_none, State) ->
    #state{torrent_id=TorrentID, remote_state=RemoteState, remote_config=RemoteConf} = State,
    etorrent_peerconf:fast(RemoteConf) orelse erlang:error(badarg),
    NewRemoteState = etorrent_peerstate:hasnone(RemoteState),
    Pieceset = etorrent_peerstate:pieces(NewRemoteState),
    ok = etorrent_scarcity:add_peer(TorrentID, Pieceset),
    NewState = State#state{remote_state=NewRemoteState},
    {ok, NewState};

handle_message(have_all, State) ->
    #state{torrent_id=TorrentID, remote_state=RemoteState, remote_config=RemoteConf} = State,
    etorrent_peerconf:fast(RemoteConf) orelse erlang:error(badarg),
    NewRemoteState = etorrent_peerstate:hasall(RemoteState),
    Pieceset = etorrent_peerstate:pieces(NewRemoteState),
    ok = etorrent_scarcity:add_peer(TorrentID, Pieceset),
    NewState = State#state{remote_state=NewRemoteState},
    {ok, NewState};

handle_message({bitfield, Bitfield}, State) ->
    #state{torrent_id=TorrentID, local_state=LocalState, remote_state=RemoteState} = State,
    NewRemoteState = etorrent_peerstate:hasset(Bitfield, RemoteState),
    Pieceset = etorrent_peerstate:pieces(NewRemoteState),
    ok = etorrent_scarcity:add_peer(TorrentID, Pieceset),
    %%IsSeeder andalso etorrent_table:statechange_peer(self(), seeder),
    NewState = State#state{remote_state=NewRemoteState},
    ok = etorrent_peer_control:check_interest(NewRemoteState, LocalState),
    {ok, NewState};

handle_message({piece, Index, Offset, Data}, State) ->
    #state{torrent_id=TorrentID, download=Download, local_state=LocalState} = State,
    Length = byte_size(Data),
    Requests = etorrent_peerstate:requests(LocalState),
    NewLocal = case etorrent_rqueue:is_head(Index, Offset, Length, Requests) of
        true ->
            ok = etorrent_download:chunk_fetched(Index, Offset, Length, Download),
            ok = etorrent_io:write_chunk(TorrentID, Index, Offset, Data),
            ok = etorrent_download:chunk_stored(Index, Offset, Length, Download),
            ok = etorrent_peerstate:check_queue(self()),
            NewRequests = etorrent_rqueue:pop(Requests),
            etorrent_peerstate:requests(NewRequests, LocalState);
        false ->
            %% Stray piece, we could try to get hold of it but for now we just
            %% throw it on the floor.
            Requests
    end,
    NewState = State#state{local_state=NewLocal},
    {ok, NewState};

handle_message({extended, 0, _Data}, State) ->
    #state{local_config=LocalConf} = State,
    etorrent_peerconf:extended(LocalConf) orelse erlang:error(badarg),
    %% Disable the extended messaging for now,
    %?INFO([{extended_message, etorrent_bcoding:decode(BCode)}]),
    %% We could consider storing the information here, if needed later on,
    %% but for now we simply ignore that.
    {ok, State};

handle_message(Unknown, State) ->
    ?WARN([unknown_message, Unknown]),
    {stop, normal, State}.


% @doc Initialize the connection, depending on the way the connection is
connection_initialize(incoming, State) ->
    #state{
        torrent_id=TorrentID,
        socket=Socket,
        info_hash=Infohash,
        local_config=LocalConf} = State,
    Extended = etorrent_peerconf:extended(LocalConf),
    LocalID = etorrent_peerstate:peerid(LocalConf),
    case etorrent_proto_wire:complete_handshake(Socket, Infohash, LocalID) of
        ok ->
            SendPid = complete_connection_setup(Socket, TorrentID, Extended),
            NewState = State#state{send_pid=SendPid},
            {ok, NewState};
        {error, stop} ->
            {stop, normal}
    end;

connection_initialize(outgoing, State) ->
    #state{
        torrent_id=TorrentID,
        socket=Socket,
        local_config=LocalConf} = State,
    Extended = etorrent_peerconf:extended(LocalConf),
    SendPid = complete_connection_setup(Socket, TorrentID, Extended),
    NewState = State#state{send_pid=SendPid},
    {ok, NewState}.

%%--------------------------------------------------------------------
%% Function: complete_connection_setup(Socket, TorrentId, ExtendedMSG)
%%              -> SendPid
%% Description: Do the bookkeeping needed to set up the peer:
%%    * enable passive messaging mode on the socket.
%%    * Start the send pid
%%    * Send off the bitfield
%%--------------------------------------------------------------------
complete_connection_setup(Socket, TorrentId, Extended) ->
    SendPid = gproc:lookup_local_name({peer, Socket, sender}),
    BF = etorrent_piece_mgr:bitfield(TorrentId),
    Extended andalso etorrent_peer_send:extended_msg(SendPid),
    etorrent_peer_send:bitfield(SendPid, BF),
    SendPid.
