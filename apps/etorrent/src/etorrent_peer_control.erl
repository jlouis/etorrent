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
-export([start_link/7, choke/1, unchoke/1, have/2, initialize/2,
        incoming_msg/2, stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).
-export([format_status/2]).

-record(state, { remote_peer_id               :: none_set | binary(),
                 local_peer_id                :: binary(),
                 info_hash                    :: binary(),

		 %% Peer support extended messages
		 extended_messaging = false   :: boolean(),
		 %% Peer uses fast extension
                 fast_extension = false       :: boolean(),
		 %% How many pieces are there left before the peer
		 %% has every pieces?
                 pieces_left                  :: integer(),
                 seeder = false               :: boolean(),
                 socket = none                :: gen_tcp:socket(),

                 remote_choked = true         :: boolean(),

                 local_interested = false     :: boolean(),

                 remote_request_set = gb_sets:empty() :: gb_set(),

                 piece_set = unknown          :: unknown | gb_set(),

		 %% Are we in endgame mode?
                 endgame = false              :: boolean(),

                 send_pid                     :: pid(),

                 rate                         :: etorrent_rate:rate(),
                 torrent_id                   :: integer() }).

-define(DEFAULT_CHUNK_SIZE, 16384). % Default size for a chunk. All clients use this.
-define(HIGH_WATERMARK, 30). % How many chunks to queue up to
-define(LOW_WATERMARK, 5).  % Requeue when there are less than this number of pieces in queue

-ignore_xref([{start_link, 6}]).

%%====================================================================

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

%% @doc Tell the peer we have just received piece PieceNumber.
%% <p>The intended caller of this function is the {@link etorrent_piece_mgr}</p>
%% @end
have(Pid, PieceNumber) ->
    gen_server:cast(Pid, {have, PieceNumber}).

%% @doc We got a chunk while in endgame mode, handle it.
%% <p>The logic is that the chunk may be queued up for this peer. We
%% wish to either cancel the request or remove it from the request
%% queue before it is sent out if possible.</p>
%% @end
endgame_got_chunk(Pid, Chunk) ->
    gen_server:cast(Pid, {endgame_got_chunk, Chunk}).

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
init([TrackerUrl, LocalPeerId, InfoHash, Id, {IP, Port}, Caps, Socket]) ->
    random:seed(now()),
    ok = etorrent_table:new_peer(TrackerUrl, IP, Port, Id, self(), leeching),
    ok = etorrent_choker:monitor(self()),
    {value, NumPieces} = etorrent_torrent:num_pieces(Id),
    gproc:add_local_name({peer, Socket, control}),
    {ok, #state{
       socket = Socket,
       pieces_left = NumPieces,
       local_peer_id = LocalPeerId,
       remote_request_set = gb_sets:empty(),
       info_hash = InfoHash,
       torrent_id = Id,
       extended_messaging = proplists:get_bool(extended_messaging, Caps)}}.

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
        {stop, NS} -> {stop, normal, NS};
        {stop, Reason, NS} -> {stop, Reason, NS}
    end;
handle_cast(choke, S) ->
    etorrent_peer_send:choke(S#state.send_pid),
    {noreply, S};
handle_cast(unchoke, S) ->
    etorrent_peer_send:unchoke(S#state.send_pid),
    {noreply, S};
handle_cast(interested, S) ->
    statechange_interested(S#state.local_interested, S#state.send_pid, true),
    {noreply, S#state {local_interested = true}};
handle_cast({have, PN}, #state { piece_set = unknown, send_pid = SPid } = S) ->
    etorrent_peer_send:have(SPid, PN),
    {noreply, S};
handle_cast({have, PN}, #state { piece_set = PS, send_pid = SPid } = S) ->
    case gb_sets:is_element(PN, PS) of
        true -> ok;
        false -> ok = etorrent_peer_send:have(SPid, PN)
    end,
    Pruned = gb_sets:delete_any(PN, PS),
    {noreply, S#state { piece_set = Pruned }};
handle_cast({endgame_got_chunk, {chunk, Index, Offset, Len}},
	    #state { torrent_id = Id, send_pid = SPid, remote_request_set = RS } = S) ->
    Chunk = {Index, Offset, Len},
    R = handle_endgame_got_chunk(Chunk, SPid, RS),
    etorrent_chunk_mgr:endgame_remove_chunk(SPid, Id, Chunk),
    {noreply, S#state { remote_request_set = R }};
handle_cast(try_queue_pieces, S) ->
    {ok, NS} = try_to_queue_up_pieces(S),
    {noreply, NS};
handle_cast(stop, S) ->
    {stop, normal, S};
handle_cast(Msg, State) ->
    ?WARN([unknown_msg, Msg]),
    {noreply, State}.


%% @private
handle_info({tcp, _P, _Packet}, State) ->
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
    Term = [{remote_peer_id, S#state.remote_peer_id},
	    {info_hash,      S#state.info_hash},
	    {socket_info,    IPPort}],
    [{data,  [{"State",  Term}]}].
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Func: handle_message(Msg, State) -> {ok, NewState} | {stop, Reason, NewState}
%% Description: Process an incoming message Msg from the wire. Return either
%%  {ok, S} if the processing was ok, or {stop, Reason, S} in case of an error.
%%--------------------------------------------------------------------
-spec handle_message(_,_) -> {'ok',_} | {'stop',_,_}.
handle_message(keep_alive, S) ->
    {ok, S};
handle_message(choke, S) ->
    ok = etorrent_peer_states:set_choke(S#state.torrent_id, self()),
    NS = case S#state.fast_extension of
             true -> S;
	     false ->
		 %% Put chunks back
		 ok = etorrent_chunk_mgr:putback_chunks(self()),
		 %% Tell other peers that there is 0xf00d!
		 etorrent_table:foreach_peer(S#state.torrent_id,
					     fun(P) -> try_queue_pieces(P) end),
		 %% Clean up the request set.
		 S#state{ remote_request_set = gb_sets:empty() }
         end,
    {ok, NS#state { remote_choked = true }};
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
handle_message({have, PieceNum}, S) -> peer_have(PieceNum, S);
handle_message({suggest, Idx}, S) ->
    ?INFO([{peer_id, S#state.remote_peer_id}, {suggest, Idx}]),
    {ok, S};
handle_message(have_none, #state { piece_set = PS } = S) when PS =/= unknown ->
    {stop, normal, S};
handle_message(have_none, #state { fast_extension = true, torrent_id = Torrent_Id } = S) ->
    {value, Size} = etorrent_torrent:num_pieces(Torrent_Id),
    {ok, S#state { piece_set = gb_sets:new(),
                   pieces_left = Size,
                   seeder = false}};
handle_message(have_all, #state { piece_set = PS }) when PS =/= unknown ->
    {error, piece_set_out_of_band};
handle_message(have_all, #state { fast_extension = true, torrent_id = Torrent_Id } = S) ->
    {value, Size} = etorrent_torrent:num_pieces(Torrent_Id),
    FullSet = gb_sets:from_list(lists:seq(0, Size - 1)),
    {ok, S#state { piece_set = FullSet,
                   pieces_left = 0,
                   seeder = true }};
handle_message({bitfield, _BF},
    #state { piece_set = PS, socket = Socket, remote_peer_id = RemotePid })
            when PS =/= unknown ->
    {ok, {IP, Port}} = inet:peername(Socket),
    etorrent_peer_mgr:enter_bad_peer(IP, Port, RemotePid),
    {error, piece_set_out_of_band};
handle_message({bitfield, BitField},
        #state { torrent_id = Torrent_Id, pieces_left = Pieces_Left,
                 remote_peer_id = RemotePid } = S) ->
    {value, Size} = etorrent_torrent:num_pieces(Torrent_Id),
    {ok, PieceSet} =
        etorrent_proto_wire:decode_bitfield(Size, BitField),
    Left = Pieces_Left - gb_sets:size(PieceSet),
    case Left of
        0  -> ok = etorrent_table:statechange_peer(self(), seeder);
        _N -> ok
    end,
    case etorrent_piece_mgr:check_interest(Torrent_Id, PieceSet) of
        {interested, Pruned} ->
            statechange_interested(S#state.local_interested, S#state.send_pid, true),
            NS = S#state {piece_set = gb_sets:from_list(Pruned),
                            pieces_left = Left,
                            seeder = Left == 0,
                            local_interested = true},
            {ok, NS};
        not_interested ->
            {ok, S#state{piece_set = gb_sets:empty(), pieces_left = Left,
                         seeder = Left == 0}};
        invalid_piece ->
            {stop, {invalid_piece_2, RemotePid}, S}
    end;
handle_message({piece, Index, Offset, Data}, #state { remote_request_set = RS } = S) ->
    case handle_got_chunk(Index, Offset, Data, RS,
			  S#state.torrent_id) of
	{ok, RS} ->
	    try_to_queue_up_pieces(S); % No change on RS
	{ok, NRS} ->
	    handle_endgame(S#state.torrent_id,
			   {Index, Offset, byte_size(Data)}, S#state.endgame),
	    try_to_queue_up_pieces(S#state { remote_request_set = NRS})
    end;
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


%% @doc handle the case where we get a chunk while in endgame mode.
%%   Note: This is when we get it from <i>another</i> peer than ourselves
%% @end
handle_endgame_got_chunk({Index, Offset, Len}, SendPid, RSet) ->
    case gb_sets:is_element({Index, Offset, Len}, RSet) of
	true ->
	    %% Delete the element from the request set.
	    etorrent_peer_send:cancel(SendPid, Index, Offset, Len),
	    gb_sets:del_element({Index, Offset, Len}, RSet);
	false ->
	    %% Not an element in the request queue, ignore
	    RSet
    end.

%% @doc Handle the case where we may be in endgame correctly.
handle_endgame(_TorrentId, _Chunk, false) -> ok;
handle_endgame(TorrentId, {Index, Offset, Len}, true) ->
    case etorrent_chunk_mgr:mark_fetched(TorrentId,
					 {Index, Offset, Len}) of
	found -> ok;
	assigned ->
	    F = fun(P) ->
			endgame_got_chunk(P, {chunk, Index, Offset, Len})
		end,
	    etorrent_table:foreach_peer(TorrentId, F)
    end.

%% @doc Process an incoming chunk in normal mode
%%   returns an updated request set
%% @end
handle_got_chunk(Index, Offset, Data, RSet, TorrentId) ->
    case gb_sets:is_element({Index, Offset, byte_size(Data)}, RSet) of
	true ->
            ok = etorrent_chunk_mgr:store_chunk(TorrentId,
                                                {Index, Offset, Data}),
            RS = gb_sets:del_element({Index, Offset, byte_size(Data)}, RSet),
            {ok, RS};
        false ->
            %% Stray piece, we could try to get hold of it but for now we just
            %%   throw it on the floor.
            {ok, RSet}
    end.

%% @doc Description: Try to queue up requests at the other end.
%%   Is called in many places with the state as input as the final thing
%%   it will check if we can queue up pieces and add some if needed.
%% @end
try_to_queue_up_pieces(#state { remote_choked = true } = S) ->
    {ok, S};
try_to_queue_up_pieces(S) ->
    case gb_sets:size(S#state.remote_request_set) of
        N when N > ?LOW_WATERMARK ->
            {ok, S};
        %% Optimization: Only replenish pieces modulo some N
        N when is_integer(N) ->
            PiecesToQueue = ?HIGH_WATERMARK - N,
            case etorrent_chunk_mgr:pick_chunks(S#state.torrent_id,
                                                S#state.piece_set,
                                                PiecesToQueue) of
                not_interested ->
                    statechange_interested(S#state.local_interested, S#state.send_pid, false),
                    {ok, S#state{local_interested = false}};
                none_eligible -> {ok, S};
                {ok, Items} -> queue_items(Items, S);
                {endgame, Items} -> queue_items(Items, S#state { endgame = true })
            end
    end.

%% @doc Send chunk messages for each chunk we decided to queue.
%%   also add these chunks to the piece request set.
%% @end
-type chunk() :: {integer(), integer()}.
-spec queue_items([{integer(), [chunk()]}], #state{}) -> {ok, #state{}}.
queue_items(ChunkList, S) ->
    RSet = queue_items(ChunkList, S#state.send_pid, S#state.remote_request_set),
    {ok, S#state { remote_request_set = RSet }}.

-spec queue_items([{integer(), [chunk()]}], pid(), gb_set()) -> gb_set().
queue_items([], _SendPid, Set) -> Set;
queue_items([{Pn, Chunks} | Rest], SendPid, Set) ->
    NT = lists:foldl(
      fun ({Offset, Size}, T) ->
              case gb_sets:is_element({Pn, Offset, Size}, T) of
                  true ->
                      Set;
                  false ->
                      etorrent_peer_send:local_request(SendPid,
                                                         {Pn, Offset, Size}),
                      gb_sets:add_element({Pn, Offset, Size}, T)
              end
      end,
      Set,
      Chunks),
    queue_items(Rest, SendPid, NT).

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

%%--------------------------------------------------------------------
%% @spec statechange_interested(WasInterested, SendPid, GoInterested)
%%          -> ok
%% @doc Set interested in peer or not according to what GoInterested
%%      is, if not yet.
%% @end
%%--------------------------------------------------------------------
statechange_interested(true, _, true) ->
    ok;
statechange_interested(false, SendPid, true) ->
    etorrent_peer_send:interested(SendPid),
    ok;
statechange_interested(false, _, false) ->
    ok;
statechange_interested(true, SendPid, false) ->
    etorrent_peer_send:not_interested(SendPid),
    ok.

peer_have(PN, #state { piece_set = unknown } = S) ->
    peer_have(PN, S#state {piece_set = gb_sets:new()});
peer_have(PN, S) ->
    case etorrent_piece_mgr:valid(S#state.torrent_id, PN) of
        true ->
            Left = S#state.pieces_left - 1,
            case peer_seeds(S#state.torrent_id, Left) of
                ok ->
                    case etorrent_piece_mgr:interesting(S#state.torrent_id, PN) of
                        true ->
                            PS = gb_sets:add_element(PN, S#state.piece_set),
                            NS = S#state { piece_set = PS, pieces_left = Left, seeder = Left == 0},
                            case S#state.local_interested of
                                true ->
                                    try_to_queue_up_pieces(NS);
                                false ->
                                    statechange_interested(NS#state.local_interested,
                                                            NS#state.send_pid, true),
                                    try_to_queue_up_pieces(NS#state{local_interested = true})
                            end;
                        false ->
                            NSS = S#state { pieces_left = Left, seeder = Left == 0},
                            {ok, NSS}
                    end;
                stop -> {stop, S}
            end;
        false ->
            {ok, {IP, Port}} = inet:peername(S#state.socket),
            etorrent_peer_mgr:enter_bad_peer(IP, Port, S#state.remote_peer_id),
            {stop, normal, S}
    end.

peer_seeds(Id, 0) ->
    ok = etorrent_table:statechange_peer(self(), seeder),
    case etorrent_torrent:is_seeding(Id) of
        true  -> stop;
        false -> ok
    end;
peer_seeds(_Id, _N) -> ok.


