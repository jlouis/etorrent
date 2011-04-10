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

-type torrentid() :: etorrent_types:torrent_id().
-type pieceset() :: etorrent_pieceset:pieceset().
-type rqueue() :: etorrent_rqueue:rqueue().

-record(state, {
    remote_peer_id :: none_set | binary(),
    local_peer_id = exit(required) :: binary(),
    info_hash = exit(required) ::  binary(),

    %% Peer support extended messages
    extended_messaging = false:: boolean(),
    %% Peer uses fast extension
    fast_extension = false :: boolean(),
    %% Does the peer have all pieces?
    seeder = false :: boolean(),
    socket = none  :: none | gen_tcp:socket(),

    remote_choked = true :: boolean(),
    local_interested = false :: boolean(),
    remote_request_set = exit(required) :: rqueue(),

    %% Keep two piecesets, the set of pieces that we have
    %% validated, and the set of pieces that the peer has.
    remote_pieces = unknown :: unknown | pieceset(),
    local_pieces  = unknown :: unknown | pieceset(),

    download = exit(required) :: etorrent_download:tservices(),
    send_pid :: pid(),
    rate     = exit(required) :: etorrent_rate:rate(),
    torrent_id = exit(required) :: integer()}).

-define(DEFAULT_CHUNK_SIZE, 16384). % Default size for a chunk. All clients use this.
-define(HIGH_WATERMARK, 30). % How many chunks to queue up to
-define(LOW_WATERMARK, 5).  % Requeue when there are less than this number of pieces in queue

-ignore_xref([{start_link, 6}]).

%%====================================================================

%% @doc Register the current process as a peer process
%% @end
register_server(TorrentID, PeerID) ->
    etorrent_utils:register(server_name(TorrentID, PeerID)),
    etorrent_utils:register_member(group_name(TorrentID)).

%% @doc Lookup the process id of a specific peer.
%% @end
lookup_server(TorrentID, PeerID) ->
    etorrent_utils:lookup(server_name(TorrentID, PeerID)).

%% @doc
%% @end
await_server(TorrentID, PeerID) ->
    etorrent_utils:await(server_name(TorrentID, PeerID)).

%% @doc
%% @end
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

%% @doc Request this this peer try queue up pieces.
%% <p>Used in certain situations where another peer gives back
%% chunks. This call ensures progress by giving other peers a chance
%% at grabbing the given-back pieces.</p>
%% @end
try_queue_pieces(Pid) ->
    gen_server:cast(Pid, try_queue_pieces).

%% @doc Inject an incoming message to the process.
%% <p>This is the main "Handle-incoming-messages" call. The intended
%% caller is {@link etorrent_peer_recv}, whenever a message arrives on
%% the socket.</p>
%% @end
incoming_msg(Pid, Msg) ->
    gen_server:cast(Pid, {incoming_msg, Msg}).

%%====================================================================

%% @private
init([TrackerUrl, LocalPeerId, InfoHash, TorrentID, {IP, Port}, Caps, Socket]) ->
    %% Use socket handle as remote peer-id.
    register_server(TorrentID, Socket),
    random:seed(now()),
    ok = etorrent_table:new_peer(TrackerUrl, IP, Port, TorrentID, self(), leeching),
    ok = etorrent_choker:monitor(self()),
    Download = etorrent_download:await_servers(TorrentID),
    {value, NumPieces} = etorrent_torrent:num_pieces(TorrentID),
    Requests = etorrent_rqueue:new(),
    Extended = proplists:get_bool(extended_messaging, Caps),
    State = #state{
       torrent_id=TorrentID,
       socket = Socket,
       local_peer_id = LocalPeerId,
       remote_request_set=Requests,
       info_hash=InfoHash,
       extended_messaging=Extended,
       download=Download},
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
    statechange_interested(State, true),
    {noreply, State#state{local_interested=true}};
handle_cast(try_queue_pieces, S) ->
    {ok, NS} = try_to_queue_up_pieces(S),
    {noreply, NS};
handle_cast(stop, S) ->
    {stop, normal, S};
handle_cast(Msg, State) ->
    ?WARN([unknown_msg, Msg]),
    {noreply, State}.


%% @private
handle_info({chunk, {fetched, Index, Offset, Length, _}}, State) ->
    #state{send_pid=SendPid, remote_request_set=Requests} = State,
    Hasrequest = etorrent_rqueue:member(Index, Offset, Length, Requests),
    NewRequests = if
        not Hasrequest ->
            Requests;
        Hasrequest ->
            etorrent_peer_send:cancel(SendPid, Index, Offset, Length),
            etorrent_rqueue:delete(Index, Offset, Length, Requests)
    end,
    NewState = State#state{remote_request_set=NewRequests},
    {noreply, NewState};

handle_info({piece, {valid, Piece}}, State) ->
    #state{send_pid=SendPid} = State,
    etorrent_peer_send:have(SendPid, Piece),
    {noreply, State};

handle_info({piece, {unassigned, _}}, State) ->
    {ok, NewState} = try_to_queue_up_pieces(State),
    {noreply, NewState};

handle_info({download, Update}, State) ->
    #state{download=Download} = State,
    NewDownload = etorrent_download:update(Update, Download),
    NewState = State#state{download=NewDownload},
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
    IPPort = case inet:peername(S#state.socket) of
		 {ok, IPP} -> IPP;
		 {error, Reason} -> {port_error, Reason}
	     end,
    Term = [
        {torrent_id,     S#state.torrent_id},
        {remote_peer_id, S#state.remote_peer_id},
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
        fast_extension=FastEnabled,
        remote_request_set=Requests,
        download=Download} = State,
    ok = etorrent_peer_states:set_choke(TorrentID, self()),
    NewState = case FastEnabled of
        true ->
            %% If the Fast Extension is enabled a CHOKE message does
            %% not imply that all outstanding requests are dropped.
            State#state{remote_choked=true};
        false ->
            %% A CHOKE message implies that all outstanding requests has been dropped.
            Chunks = etorrent_rqueue:to_list(Requests),
            ok = etorrent_download:chunks_dropped(Chunks, Download),
            NewRequests = etorrent_rqueue:flush(Requests),
            etorrent_table:foreach_peer(TorrentID, fun try_queue_pieces/1),
            State#state{remote_choked=true, remote_request_set=NewRequests}
    end,
    {ok, NewState};
handle_message(unchoke, S) ->
    ok = etorrent_peer_states:set_unchoke(S#state.torrent_id, self()),
    try_to_queue_up_pieces(S#state{remote_choked = false});
handle_message(interested, S) ->
    ok = etorrent_peer_states:set_interested(S#state.torrent_id, self()),
    ok = etorrent_peer_send:check_choke(S#state.send_pid),
    {ok, S};
handle_message(not_interested, S) ->
    ok = etorrent_peer_states:set_not_interested(S#state.torrent_id, self()),
    ok = etorrent_peer_send:check_choke(S#state.send_pid),
    {ok, S};
handle_message({request, Index, Offset, Len}, S) ->
    etorrent_peer_send:remote_request(S#state.send_pid, Index, Offset, Len),
    {ok, S};
handle_message({cancel, Index, Offset, Len}, S) ->
    etorrent_peer_send:cancel(S#state.send_pid, Index, Offset, Len),
    {ok, S};
handle_message({have, PieceNum}, S) ->
    peer_have(PieceNum, S);
handle_message({suggest, Idx}, S) ->
    ?INFO([{peer_id, S#state.remote_peer_id}, {suggest, Idx}]),
    {ok, S};
handle_message(have_none, #state{remote_pieces=PS}=S) when PS =/= unknown ->
    {stop, normal, S};
handle_message(have_none, #state{fast_extension=true, torrent_id=TorrentID}=S) ->
    {value, NumPieces} = etorrent_torrent:num_pieces(TorrentID),
    Pieceset = etorrent_pieceset:new(NumPieces),
    ok = etorrent_scarcity:add_peer(TorrentID, Pieceset),
    NewState = S#state{
        remote_pieces=Pieceset,
        seeder=false},
    {ok, NewState};

handle_message(have_all, #state{remote_pieces=PS}) when PS =/= unknown ->
    {error, remote_pieces_out_of_band};

handle_message(have_all, #state{fast_extension=true, torrent_id=TorrentID}=S) ->
    {value, NumPieces} = etorrent_torrent:num_pieces(TorrentID),
    AllPieces = lists:seq(0, NumPieces - 1),
    FullSet = etorrent_pieceset:from_list(AllPieces, NumPieces),
    ok = etorrent_scarcity:add_peer(TorrentID, FullSet),
    NewState = S#state{
        remote_pieces=FullSet,
        seeder=true},
    {ok, NewState};

handle_message({bitfield, _}, State) when State#state.remote_pieces /= unknown ->
    #state{socket=Socket, remote_peer_id=RemoteID} = State,
    {ok, {IP, Port}} = inet:peername(Socket),
    etorrent_peer_mgr:enter_bad_peer(IP, Port, RemoteID),
    {error, remote_pieces_out_of_band};

handle_message({bitfield, Bin}, State) ->
    #state{
        torrent_id=TorrentID,
        remote_peer_id=RemoteID} = State,
    {value, Numpieces} = etorrent_torrent:num_pieces(TorrentID),
    Pieceset = etorrent_pieceset:from_binary(Bin, Numpieces),
    ok = etorrent_scarcity:add_peer(TorrentID, Pieceset),
    Left = Numpieces - etorrent_pieceset:size(Pieceset),
    IsSeeder = Left == 0,
    IsSeeder andalso etorrent_table:statechange_peer(self(), seeder),
    NewState = State#state{
        remote_pieces=Pieceset,
        seeder=IsSeeder},
    case etorrent_piece_mgr:check_interest(TorrentID, Pieceset) of
        {interested, _} ->
            statechange_interested(NewState, true),
            {ok, NewState#state{local_interested=true}};
        not_interested ->
            {ok, NewState};
        invalid_piece ->
            {stop, {invalid_piece_2, RemoteID}, State}
    end;

handle_message({piece, Index, Offset, Data}, State) ->
    #state{
        torrent_id=TorrentID,
        download=Download,
        remote_request_set=Requests} = State,
    Length = byte_size(Data),
    NewRequests = case etorrent_rqueue:is_head(Index, Offset, Length, Requests) of
        true ->
            ok = etorrent_download:chunk_fetched(Index, Offset, Length, Download),
            ok = etorrent_io:write_chunk(TorrentID, Index, Offset, Data),
            ok = etorrent_download:chunk_stored(Index, Offset, Length, Download),
            etorrent_rqueue:pop(Requests);
        false ->
            %% Stray piece, we could try to get hold of it but for now we just
            %% throw it on the floor.
            Requests
    end,
    NewState = State#state{remote_request_set=NewRequests},
	try_to_queue_up_pieces(NewState);

handle_message({extended, _, _}, S) when S#state.extended_messaging == false ->
    %% We do not accept extended messages unless they have been enabled.
    {stop, normal, S};
handle_message({extended, 0, _BCode}, S) ->
    %% Disable the extended messaging for now,
    %?INFO([{extended_message, etorrent_bcoding:decode(BCode)}]),
    %% We could consider storing the information here, if needed later on,
    %%   but for now we simply ignore that.
    {ok, S};
handle_message(Unknown, S) ->
    ?WARN([unknown_message, Unknown]),
    {stop, normal, S}.


%% @doc Description: Try to queue up requests at the other end.
%%   Is called in many places with the state as input as the final thing
%%   it will check if we can queue up pieces and add some if needed.
%% @end
try_to_queue_up_pieces(#state { remote_choked = true } = S) ->
    {ok, S};
try_to_queue_up_pieces(State) ->
    #state{
        send_pid=SendPid,
        remote_pieces=Pieceset,
        remote_request_set=Requests,
        download=Download} = State,
    case etorrent_rqueue:is_low(Requests) of
        false ->
            {ok, State};
        true ->
            Numchunks = etorrent_rqueue:needs(Requests),
            case etorrent_download:request_chunks(Numchunks, Pieceset, Download) of
                {ok, not_interested} ->
                    statechange_interested(State, false),
                    {ok, State#state{local_interested=false}};
                {ok, assigned} ->
                    {ok, State};
                {ok, Chunks} ->
                    NewRequests = etorrent_rqueue:push(Chunks, Requests),
                    [etorrent_peer_send:local_request(SendPid, Chunk)
                    || Chunk <- Chunks],
                    NewState = State#state{remote_request_set=NewRequests},
                    {ok, NewState}
            end
    end.

% @doc Initialize the connection, depending on the way the connection is
connection_initialize(incoming, S) ->
    case etorrent_proto_wire:complete_handshake(
                    S#state.socket,
                    S#state.info_hash,
                    S#state.local_peer_id) of
        ok -> SendPid = complete_connection_setup(S#state.socket,
                                            S#state.torrent_id,
                                            S#state.extended_messaging),
              NS = S#state { remote_peer_id = none_set,
                            fast_extension = false,
                            send_pid = SendPid},
              {ok, NS};
        {error, stop} -> {stop, normal}
    end;
connection_initialize(outgoing, S) ->
    SendPid = complete_connection_setup(S#state.socket,
                                        S#state.torrent_id,
                                        S#state.extended_messaging),
    {ok, S#state{send_pid = SendPid}}.

%%--------------------------------------------------------------------
%% Function: complete_connection_setup(Socket, TorrentId, ExtendedMSG)
%%              -> SendPid
%% Description: Do the bookkeeping needed to set up the peer:
%%    * enable passive messaging mode on the socket.
%%    * Start the send pid
%%    * Send off the bitfield
%%--------------------------------------------------------------------
complete_connection_setup(Socket, TorrentId, ExtendedMSG) ->
    SendPid = gproc:lookup_local_name({peer, Socket, sender}),
    BF = etorrent_piece_mgr:bitfield(TorrentId),
    case ExtendedMSG of
        true -> etorrent_peer_send:extended_msg(SendPid);
        false -> ignore
    end,
    etorrent_peer_send:bitfield(SendPid, BF),
    SendPid.

%% @doc Set interested in peer or not according to what GoInterested
%%      is, if not yet.
%% @end
statechange_interested(State, IsInterested) ->
    #state{
        local_interested=WasInterested,
        send_pid=SendPid} = State,
    case {WasInterested, IsInterested} of
        {true, true}   -> ok;
        {false, false} -> ok;
        {false, true}  -> etorrent_peer_send:interested(SendPid);
        {true, false}  -> etorrent_peer_send:not_interested(SendPid)
    end.

peer_have(PN, #state{remote_pieces=unknown}=State) ->
    #state{torrent_id=TorrentID} = State,
    {value, NumPieces} = etorrent_torrent:num_pieces(TorrentID),
    Pieceset = etorrent_pieceset:new(NumPieces),
    NewState = State#state{remote_pieces=Pieceset},
    peer_have(PN, NewState);
peer_have(Piece, State) ->
    #state{
        torrent_id=TorrentID,
        remote_pieces=Pieceset,
        local_interested=WasInterested} = State,
    Valid = etorrent_pieceset:is_valid(Piece, Pieceset),
    Member = Valid andalso etorrent_pieceset:is_member(Piece, Pieceset),

    %% Only update the set of valid pieces that the peer provides if
    %% the piece index is valid and it's the first and only notification.
    NewPieceset = if
        Valid andalso not Member ->
            IPieceset = etorrent_pieceset:insert(Piece, Pieceset),
            ok = etorrent_scarcity:add_piece(TorrentID, Piece, IPieceset),
            IPieceset;
        true -> false
    end,

    %% Only check if we are interested in the pieces that this peer provides
    %% if we are not already interested and we're not going to disconnect.
    %% If we were already interested this notification does not change that.
    IsInterested = if
        Valid andalso not Member andalso not WasInterested ->
            etorrent_piece_mgr:interesting(TorrentID, Piece);
        true ->
            WasInterested
    end,

    %% Only check if the peer became a seeder if we are also seeding.
    IsSeeding = etorrent_torrent:is_seeding(TorrentID),
    PeerSeeds = if
        Valid andalso not Member andalso IsSeeding ->
            Numpieces = etorrent_pieceset:capacity(NewPieceset),
            Havepieces = etorrent_pieceset:size(NewPieceset),
            Havepieces == Numpieces;
        %% Default to false, we're losing information here because we never
        %% check if another peer is seeding if we are not seeding the torrent.
        true -> false
    end,

    
    if  %% Mark the peer as a bad apple if the piece index is invalid
        %% for this torrent or if the have-message is a duplicate.
        (not Valid) orelse (Valid andalso Member) ->
            {ok, {IP, Port}} = inet:peername(State#state.socket),
            etorrent_peer_mgr:enter_bad_peer(IP, Port, State#state.remote_peer_id),
            {stop, normal, State};

        %% If both we and the peer is seeding there is not point in staying
        %% connected, close the connection.
        IsSeeding andalso PeerSeeds ->
            {stop, normal, State};

        %% If we became interested, notify the peer and queue up some pieces.
        (not WasInterested) andalso IsInterested ->
            statechange_interested(State, true),
            NewState = State#state{
                remote_pieces=NewPieceset,
                local_interested=true},
            try_to_queue_up_pieces(NewState);

        %% If we're interested, try to aquire some new requests using the
        %% updated set of available pieces.
        IsInterested ->
            NewState = State#state{remote_pieces=NewPieceset},
            try_to_queue_up_pieces(NewState);

        %% If we're not interested the new piece doesn't change anything.
        %% Just update the current state to include the new piece.
        not IsInterested ->
            NewState = State#state{remote_pieces=NewPieceset},
            {ok, NewState}
    end.
