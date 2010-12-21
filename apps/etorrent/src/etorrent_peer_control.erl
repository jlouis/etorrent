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
-include("types.hrl").
-include("log.hrl").

%% API
-export([start_link/6, choke/1, unchoke/1, have/2, initialize/2,
        incoming_msg/2, stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, { remote_peer_id = none,
                 local_peer_id = none,
                 info_hash = none,

		 extended_messaging = false, % Peer support extended messages
                 fast_extension = false, % Peer uses fast extension

                 %% The packet continuation stores intermediate buffering
                 %% when we only have received part of a package.
                 packet_continuation = none,
                 pieces_left, % How many pieces are there left before the peer
                              % has every pieces?
                 seeder = false,
                 socket = none,

                 remote_choked = true,

                 local_interested = false,

                 remote_request_set = none,

                 piece_set = unknown,
                 piece_request = [],

                 packet_left = none,
                 packet_iolist = [],

                 endgame = false, % Are we in endgame mode?

                 file_system_pid = none,
                 send_pid = none,

                 rate = none,
                 rate_timer = none,
                 torrent_id = none}).

-define(DEFAULT_CHUNK_SIZE, 16384). % Default size for a chunk. All clients use this.
-define(HIGH_WATERMARK, 30). % How many chunks to queue up to
-define(LOW_WATERMARK, 5).  % Requeue when there are less than this number of pieces in queue

-ignore_xref([{start_link, 6}]).

%%====================================================================

%% @doc Starts the server
%% @end
start_link(LocalPeerId, InfoHash, Id, {IP, Port}, Caps, Socket) ->
    gen_server:start_link(?MODULE, [LocalPeerId, InfoHash,
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
init([LocalPeerId, InfoHash, Id, {IP, Port}, Caps, Socket]) ->
    %% @todo: Update the leeching state to seeding when peer finished torrent.
    ok = etorrent_table:new_peer(IP, Port, Id, self(), leeching),
    ok = etorrent_choker:monitor(self()),
    {value, NumPieces} = etorrent_torrent:num_pieces(Id),
    gproc:add_local_name({peer, Socket, control}),
    %% FS = gproc:lookup_local_name({torrent, Id, fs}),
    {ok, #state{
       socket = Socket,
       pieces_left = NumPieces,
       local_peer_id = LocalPeerId,
       remote_request_set = gb_trees:empty(),
       info_hash = InfoHash,
       torrent_id = Id,
       extended_messaging = proplists:get_bool(extended_messaging, Caps)}}.
       %% file_system_pid = FS}}.

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
        {stop, NS} -> {stop, normal, NS}
    end;
handle_cast(choke, S) ->
    etorrent_peer_send:choke(S#state.send_pid),
    {noreply, S};
handle_cast(unchoke, S) ->
    etorrent_peer_send:unchoke(S#state.send_pid),
    {noreply, S};
handle_cast(interested, S) ->
    {noreply, statechange_interested(S, true)};
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
handle_cast({endgame_got_chunk, Chunk}, S) ->
    NS = handle_endgame_got_chunk(Chunk, S),
    {noreply, NS};
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

%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Func: handle_message(Msg, State) -> {ok, NewState} | {stop, Reason, NewState}
%% Description: Process an incoming message Msg from the wire. Return either
%%  {ok, S} if the processing was ok, or {stop, Reason, S} in case of an error.
%%--------------------------------------------------------------------
-spec handle_message(_,_) -> {'ok',_} | {'stop',_}.
handle_message(keep_alive, S) ->
    {ok, S};
handle_message(choke, S) ->
    ok = etorrent_peer_states:choke(S#state.torrent_id, self()),
    NS = case S#state.fast_extension of
             true -> S;
             false -> unqueue_all_pieces(S)
         end,
    {ok, NS#state { remote_choked = true }};
handle_message(unchoke, S) ->
    ok = etorrent_peer_states:unchoke(S#state.torrent_id, self()),
    try_to_queue_up_pieces(S#state{remote_choked = false});
handle_message(interested, S) ->
    ok = etorrent_peer_states:interested(S#state.torrent_id, self()),
    ok = etorrent_peer_send:check_choke(S#state.send_pid),
    {ok, S};
handle_message(not_interested, S) ->
    ok = etorrent_peer_states:not_interested(S#state.torrent_id, self()),
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
    Size = etorrent_torrent:num_pieces(Torrent_Id),
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
            {ok, statechange_interested(S#state {piece_set = gb_sets:from_list(Pruned),
                                                 pieces_left = Left,
                                                 seeder = Left == 0},
                                        true)};
        not_interested ->
            {ok, S#state{piece_set = gb_sets:empty(), pieces_left = Left,
                         seeder = Left == 0}};
        invalid_piece ->
            {stop, {invalid_piece_2, RemotePid}, S}
    end;
handle_message({piece, Index, Offset, Data}, S) ->
    {ok, NS} = handle_got_chunk(Index, Offset, Data, size(Data), S),
    try_to_queue_up_pieces(NS);
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

%%--------------------------------------------------------------------
%% Func: handle_endgame_got_chunk({chunk, Index, Offset, Len}, S) -> S
%% Description: Some other peer just downloaded {Index, Offset, Len} so try
%%   not to download it here if we can avoid it.
%%--------------------------------------------------------------------
handle_endgame_got_chunk({chunk, Index, Offset, Len}, S) ->
    case gb_trees:is_defined({Index, Offset, Len}, S#state.remote_request_set) of
        true ->
            %% Delete the element from the request set.
            RS = gb_trees:delete({Index, Offset, Len}, S#state.remote_request_set),
            etorrent_peer_send:cancel(S#state.send_pid,
                                        Index,
                                        Offset,
                                        Len),
            etorrent_chunk_mgr:endgame_remove_chunk(S#state.send_pid,
                                                    S#state.torrent_id,
                                                    {Index, Offset, Len}),
            S#state { remote_request_set = RS };
        false ->
            %% Not an element in the request queue, ignore
            etorrent_chunk_mgr:endgame_remove_chunk(S#state.send_pid,
                                                    S#state.torrent_id,
                                                    {Index, Offset, Len}),
            S
    end.

%%--------------------------------------------------------------------
%% Func: handle_got_chunk(Index, Offset, Data, Len, S) -> {ok, State}
%% Description: We just got some chunk data. Store it in the mnesia DB
%%--------------------------------------------------------------------
handle_got_chunk(Index, Offset, Data, Len, S) ->
    case gb_trees:lookup({Index, Offset, Len},
                         S#state.remote_request_set) of
        {value, Ops} ->
            ok = etorrent_chunk_mgr:store_chunk(S#state.torrent_id,
                                                {Index, Data, Ops},
                                                {Offset, Len},
                                                S#state.file_system_pid),
            %% Tell other peers we got the chunk if in endgame
            case S#state.endgame of
                true ->
                    case etorrent_chunk_mgr:mark_fetched(S#state.torrent_id,
                                                     {Index, Offset, Len}) of
                        found ->
                            ok;
                        assigned ->
			    etorrent_table:foreach_peer(
			      S#state.torrent_id,
			      fun(P) ->
				      endgame_got_chunk(
					P,
					{chunk, Index, Offset, Len})
			      end)
                    end;
                false ->
                    ok
            end,
            RS = gb_trees:delete_any({Index, Offset, Len}, S#state.remote_request_set),
            {ok, S#state { remote_request_set = RS }};
        none ->
            %% Stray piece, we could try to get hold of it but for now we just
            %%   throw it on the floor.
            {ok, S}
    end.


%%--------------------------------------------------------------------
%% Function: unqueue_all_pieces/1
%% Description: Unqueue all queued pieces at the other end. We place
%%   the earlier queued items at the end to compensate for quick
%%   choke/unchoke problems and live data.
%%--------------------------------------------------------------------
unqueue_all_pieces(S) ->
    %% Put chunks back
    ok = etorrent_chunk_mgr:putback_chunks(self()),
    %% Tell other peers that there is 0xf00d!
    etorrent_table:foreach_peer(S#state.torrent_id,
        fun(P) -> try_queue_pieces(P) end),
    %% Clean up the request set.
    S#state{ remote_request_set = gb_trees:empty() }.

%%--------------------------------------------------------------------
%% Function: try_to_queue_up_requests(state()) -> {ok, state()}
%% Description: Try to queue up requests at the other end.
%%--------------------------------------------------------------------
try_to_queue_up_pieces(#state { remote_choked = true } = S) ->
    {ok, S};
try_to_queue_up_pieces(S) ->
    case gb_trees:size(S#state.remote_request_set) of
        N when N > ?LOW_WATERMARK ->
            {ok, S};
        %% Optimization: Only replenish pieces modulo some N
        N when is_integer(N) ->
            PiecesToQueue = ?HIGH_WATERMARK - N,
            case etorrent_chunk_mgr:pick_chunks(S#state.torrent_id,
                                                S#state.piece_set,
                                                PiecesToQueue) of
                not_interested -> {ok, statechange_interested(S, false)};
                none_eligible -> {ok, S};
                {ok, Items} -> queue_items(Items, S);
                {endgame, Items} -> queue_items(Items, S#state { endgame = true })
            end
    end.

%% @doc Send chunk messages for each chunk we decided to queue.
%%   also add these chunks to the piece request set.
%% @end
-type chunk() :: {integer(), integer(), [operation()]}.
-spec queue_items([chunk()], #state{}) -> {ok, #state{}}.
queue_items(ChunkList, S) ->
    RSet = queue_items(ChunkList, S#state.send_pid, S#state.remote_request_set),
    {ok, S#state { remote_request_set = RSet }}.

-spec queue_items([{integer(), [chunk()]}], pid(), gb_tree()) -> gb_tree().
queue_items([], _SendPid, Tree) -> Tree;
queue_items([{Pn, Chunks} | Rest], SendPid, Tree) ->
    NT = lists:foldl(
      fun ({Offset, Size, Ops}, T) ->
              case gb_trees:is_defined({Pn, Offset, Size}, T) of
                  true ->
                      Tree;
                  false ->
                      etorrent_peer_send:local_request(SendPid,
                                                         {Pn, Offset, Size}),
                      gb_trees:enter({Pn, Offset, Size}, Ops, T)
              end
      end,
      Tree,
      Chunks),
    queue_items(Rest, SendPid, NT);
queue_items([{Pn, Offset, Size, Ops} | Rest], SendPid, Tree) ->
    NT = case gb_trees:is_defined({Pn, Offset, Size}, Tree) of
             true ->
                 Tree;
             false ->
                 etorrent_peer_send:local_request(SendPid,
                                                    {Pn, Offset, Size}),
                 gb_trees:enter({Pn, Offset, Size}, Ops, Tree)
         end,
    queue_items(Rest, SendPid, NT).


% @doc Initialize the connection, depending on the way the connection is
connection_initialize(Way, S) ->
    case Way of
        incoming ->
            case etorrent_proto_wire:complete_handshake(
                            S#state.socket,
                            S#state.info_hash,
                            S#state.local_peer_id) of
                ok -> {ok, NS} =
			  complete_connection_setup(
                                    S#state { remote_peer_id = none_set,
                                              fast_extension = false}),
                      {ok, NS};
                {error, stop} -> {stop, normal}
            end;
        outgoing ->
            {ok, NS} = complete_connection_setup(S),
            {ok, NS}
    end.

%%--------------------------------------------------------------------
%% Function: complete_connection_setup() -> gen_server_reply()}
%% Description: Do the bookkeeping needed to set up the peer:
%%    * enable passive messaging mode on the socket.
%%    * Start the send pid
%%    * Send off the bitfield
%%--------------------------------------------------------------------
complete_connection_setup(#state { extended_messaging = EMSG,
				   socket = Sock } = S) ->
    SendPid = gproc:lookup_local_name({peer, Sock, sender}),
    BF = etorrent_piece_mgr:bitfield(S#state.torrent_id),
    case EMSG of
	true -> etorrent_peer_send:extended_msg(SendPid);
	false -> ignore
    end,
    etorrent_peer_send:bitfield(SendPid, BF),
    {ok, S#state{send_pid = SendPid }}.

statechange_interested(#state{ local_interested = true } = S, true) ->
    S;
statechange_interested(#state{ local_interested = false, send_pid = SPid} = S, true) ->
    etorrent_peer_send:interested(SPid),
    S#state{local_interested = true};
statechange_interested(#state{ local_interested = false} = S, false) ->
    S;
statechange_interested(#state{ local_interested = true, send_pid = SPid} = S, false) ->
    etorrent_peer_send:not_interested(SPid),
    S#state{local_interested = false}.

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
                                    try_to_queue_up_pieces(statechange_interested(NS, true))
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


