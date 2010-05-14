-module(etorrent_peer_control).

-behaviour(gen_server).

-include("etorrent_mnesia_table.hrl").
-include("etorrent_rate.hrl").

%% API
-export([start_link/7, choke/1, unchoke/1, interested/1,
         have/2, complete_handshake/1, endgame_got_chunk/2,
         incoming_msg/2, try_queue_pieces/1, stop/1, complete_conn_setup/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, { remote_peer_id = none,
                 local_peer_id = none,
                 info_hash = none,

                 fast_extension = false, % Peer uses fast extension

                 %% The packet continuation stores intermediate buffering
                 %% when we only have received part of a package.
                 packet_continuation = none,
                 pieces_left,
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

                 parent = none,

                 file_system_pid = none,
                 send_pid = none,

                 rate = none,
                 rate_timer = none,
                 torrent_id = none}).

-define(DEFAULT_CHUNK_SIZE, 16384). % Default size for a chunk. All clients use this.
-define(HIGH_WATERMARK, 15). % How many chunks to queue up to
-define(LOW_WATERMARK, 5).  % Requeue when there are less than this number of pieces in queue
%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(LocalPeerId, InfoHash, FilesystemPid, Id, Parent,
          {IP, Port}, Socket) ->
    gen_server:start_link(?MODULE, [LocalPeerId, InfoHash,
                                    FilesystemPid, Id, Parent,
                                    {IP, Port}, Socket], []).

%%--------------------------------------------------------------------
%% Function: stop/1
%% Args: Pid ::= pid()
%% Description: Gracefully ask the server to stop.
%%--------------------------------------------------------------------
stop(Pid) ->
    gen_server:cast(Pid, stop).

%%--------------------------------------------------------------------
%% Function: choke(Pid)
%% Description: Choke the peer.
%%--------------------------------------------------------------------
choke(Pid) ->
    gen_server:cast(Pid, choke).

%%--------------------------------------------------------------------
%% Function: unchoke(Pid)
%% Description: Unchoke the peer.
%%--------------------------------------------------------------------
unchoke(Pid) ->
    gen_server:cast(Pid, unchoke).

%%--------------------------------------------------------------------
%% Function: interested(Pid)
%% Description: Tell the peer we are interested.
%%--------------------------------------------------------------------
interested(Pid) ->
    gen_server:cast(Pid, interested).

%%--------------------------------------------------------------------
%% Function: have(Pid, PieceNumber)
%% Description: Tell the peer we have just received piece PieceNumber.
%%--------------------------------------------------------------------
have(Pid, PieceNumber) ->
    gen_server:cast(Pid, {have, PieceNumber}).

%%--------------------------------------------------------------------
%% Function: endgame_got_chunk(Pid, Index, Offset) -> ok
%% Description: We got the chunk {Index, Offset}, handle it.
%%--------------------------------------------------------------------
endgame_got_chunk(Pid, Chunk) ->
    gen_server:cast(Pid, {endgame_got_chunk, Chunk}).

%% Complete the handshake initiated by another client.
%% TODO: We ought to do this in another place.
complete_handshake(Pid) ->
    gen_server:cast(Pid, complete_handshake).

complete_conn_setup(Pid) ->
    gen_server:cast(Pid, complete_connection_setup).

%% Request this this peer try queue up pieces.
try_queue_pieces(Pid) ->
    gen_server:cast(Pid, try_queue_pieces).

%% This message is incoming to the peer
incoming_msg(Pid, Msg) ->
    gen_server:cast(Pid, {incoming_msg, Msg}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([LocalPeerId, InfoHash, FilesystemPid, Id, Parent, {IP, Port}, Socket]) ->
    process_flag(trap_exit, true),
    %% TODO: Update the leeching state to seeding when peer finished torrent.
    ok = etorrent_peer:new(IP, Port, Id, self(), leeching),
    ok = etorrent_choker:monitor(self()), %% TODO: Perhaps call this :new ?
    [T] = etorrent_torrent:select(Id),
    {ok, #state{
       socket = Socket,
       pieces_left = T#torrent.pieces,
       parent = Parent,
       local_peer_id = LocalPeerId,
       remote_request_set = gb_trees:empty(),
       info_hash = InfoHash,
       torrent_id = Id,
       file_system_pid = FilesystemPid}}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
%% TODO: This ought to be handled elsewhere. For now, it is ok to have here,
%%  but it should be a temporary process which tries to make a connection and
%%  sets the initial stuff up.
handle_cast(complete_handshake, S) ->
    case etorrent_proto_wire:complete_handshake(S#state.socket,
                                                S#state.info_hash,
                                                S#state.local_peer_id) of
        ok ->
            complete_connection_setup(S#state { remote_peer_id = none_set,
                                                  fast_extension = false});
        {error, stop} ->
            {stop, normal, S}
    end;
handle_cast({incoming_msg, Msg}, S) ->
    case handle_message(Msg, S) of
        {ok, NS} -> {noreply, NS};
        {stop, X, NS} -> {stop, X, NS}
    end;
handle_cast(complete_connection_setup, S) ->
    error_logger:info_report(completion_of_conn_setup),
    complete_connection_setup(S);
handle_cast(choke, S) ->
    etorrent_peer_send:choke(S#state.send_pid),
    {noreply, S};
handle_cast(unchoke, S) ->
    etorrent_peer_send:unchoke(S#state.send_pid),
    {noreply, S};
handle_cast(interested, S) ->
    {noreply, statechange_interested(S, true)};
handle_cast({have, PN}, S) when S#state.piece_set =:= unknown ->
    etorrent_peer_send:have(S#state.send_pid, PN),
    {noreply, S};
handle_cast({have, PN}, S) ->
    case gb_sets:is_element(PN, S#state.piece_set) of
        true -> ok;
        false -> ok = etorrent_peer_send:have(S#state.send_pid, PN)
    end,
    {noreply, S};
handle_cast({endgame_got_chunk, Chunk}, S) ->
    NS = handle_endgame_got_chunk(Chunk, S),
    {noreply, NS};
handle_cast(try_queue_pieces, S) ->
    {ok, NS} = try_to_queue_up_pieces(S),
    {noreply, NS};
handle_cast(stop, S) ->
    {stop, normal, S};
handle_cast(_Msg, State) ->
    {noreply, State}.


%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, S) ->
    etorrent_peer:delete(self()),
    etorrent_counters:release_peer_slot(),
    _NS = unqueue_all_pieces(S),
    gen_tcp:close(S#state.socket),
    ok.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Func: handle_message(Msg, State) -> {ok, NewState} | {stop, Reason, NewState}
%% Description: Process an incoming message Msg from the wire. Return either
%%  {ok, S} if the processing was ok, or {stop, Reason, S} in case of an error.
%%--------------------------------------------------------------------
handle_message(keep_alive, S) ->
    {ok, S};
handle_message(choke, S) ->
    ok = etorrent_rate_mgr:choke(S#state.torrent_id, self()),
    NS = case S#state.fast_extension of
             true -> S;
             false -> unqueue_all_pieces(S)
         end,
    {ok, NS#state { remote_choked = true }};
handle_message(unchoke, S) ->
    ok = etorrent_rate_mgr:unchoke(S#state.torrent_id, self()),
    try_to_queue_up_pieces(S#state{remote_choked = false});
handle_message(interested, S) ->
    ok = etorrent_rate_mgr:interested(S#state.torrent_id, self()),
    ok = etorrent_peer_send:check_choke(S#state.send_pid),
    {ok, S};
handle_message(not_interested, S) ->
    ok = etorrent_rate_mgr:not_interested(S#state.torrent_id, self()),
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
    error_logger:info_report([{peer_id, S#state.remote_peer_id},
                              {suggest, Idx}]),
    {ok, S};
handle_message(have_none, S) when S#state.piece_set =/= unknown ->
    {stop, normal, S};
handle_message(have_none, S) when S#state.fast_extension =:= true ->
    Size = etorrent_torrent:num_pieces(S#state.torrent_id),
    {ok, S#state { piece_set = gb_sets:new(),
                   pieces_left = Size,
                   seeder = false}};
handle_message(have_all, S) when S#state.piece_set =/= unknown ->
    {error, piece_set_out_of_band};
handle_message(have_all, S) when S#state.fast_extension =:= true ->
    Size = etorrent_torrent:num_pieces(S#state.torrent_id),
    FullSet = gb_sets:from_list(lists:seq(0, Size - 1)),
    {ok, S#state { piece_set = FullSet,
                   pieces_left = 0,
                   seeder = true }};
handle_message({bitfield, _BF}, S) when S#state.piece_set =/= unknown ->
    {ok, {IP, Port}} = inet:peername(S#state.socket),
    etorrent_peer_mgr:enter_bad_peer(IP, Port, S#state.remote_peer_id),
    {error, piece_set_out_of_band};
handle_message({bitfield, BitField}, S) ->
    Size = etorrent_torrent:num_pieces(S#state.torrent_id),
    {ok, PieceSet} =
        etorrent_proto_wire:decode_bitfield(Size, BitField),
    Left = S#state.pieces_left - gb_sets:size(PieceSet),
    case Left of
        0  -> ok = etorrent_peer:statechange(self(), seeder);
        _N -> ok
    end,
    case etorrent_piece_mgr:check_interest(S#state.torrent_id, PieceSet) of
        interested ->
            {ok, statechange_interested(S#state {piece_set = PieceSet,
                                                 pieces_left = Left,
                                                 seeder = Left == 0},
                                        true)};
        not_interested ->
            {ok, S#state{piece_set = PieceSet, pieces_left = Left,
                         seeder = Left == 0}};
        invalid_piece ->
            {stop, {invalid_piece_2, S#state.remote_peer_id}, S}
    end;
handle_message({reject_request, Idx, Offset, Len}, S) when S#state.fast_extension =:= true ->
    unqueue_piece({Idx, Offset, Len}, S);
handle_message({piece, Index, Offset, Data}, S) ->
    case handle_got_chunk(Index, Offset, Data, size(Data), S) of
        {ok, NS} ->
            try_to_queue_up_pieces(NS)
    end;
handle_message(Unknown, S) ->
    error_logger:info_report([{unknown_message, Unknown}]),
    {stop, normal, S}.

%%--------------------------------------------------------------------
%% Func: handle_endgame_got_chunk(Index, Offset, S) -> State
%% Description: Some other peer just downloaded {Index, Offset, Len} so try
%%   not to download it here if we can avoid it.
%%--------------------------------------------------------------------
handle_endgame_got_chunk({Index, Offset, Len}, S) ->
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
            ok = etorrent_fs:write_chunk(S#state.file_system_pid,
                                         {Index, Data, Ops}),
            case etorrent_chunk_mgr:store_chunk(S#state.torrent_id,
                                                Index,
                                                {Offset, Len},
                                                self()) of
                full ->
                    etorrent_fs:check_piece(S#state.file_system_pid, Index);
                ok ->
                    ok
            end,
            %% Tell other peers we got the chunk if in endgame
            case S#state.endgame of
                true ->
                    case etorrent_chunk_mgr:mark_fetched(S#state.torrent_id,
                                                     {Index, Offset, Len}) of
                        found ->
                            ok;
                        assigned ->
                            broadcast_got_chunk({Index, Offset, Len}, S#state.torrent_id)
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


%% TODO: This will probably get pretty expensive fast. We'll just hope it doesn't
%%   kill us.
unqueue_piece({Idx, Offset, Len}, S) ->
    case gb_trees:is_defined({Idx, Offset, Len}, S#state.remote_request_set) of
        false ->
            {stop, normal, S};
        true ->
            ReqSet = gb_sets:delete({Idx, Offset, Len}, S#state.remote_request_set),
            ok = etorrent_chunk_mgr:putback_chunk(self(), {Idx, Offset, Len}),
            broadcast_queue_pieces(S#state.torrent_id),
            {noreply, S#state { remote_request_set = ReqSet }}
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
    broadcast_queue_pieces(S#state.torrent_id),
    %% Clean up the request set.
    S#state{remote_request_set = gb_trees:empty()}.

%%--------------------------------------------------------------------
%% Function: try_to_queue_up_requests(state()) -> {ok, state()}
%% Description: Try to queue up requests at the other end.
%%--------------------------------------------------------------------
try_to_queue_up_pieces(S) when S#state.remote_choked == true ->
    {ok, S};
try_to_queue_up_pieces(S) ->
    case gb_trees:size(S#state.remote_request_set) of
        N when N > ?LOW_WATERMARK ->
            {ok, S};
        %% Optimization: Only replenish pieces modulo some N
        N when is_integer(N) ->
            PiecesToQueue = ?HIGH_WATERMARK - N,
            case etorrent_chunk_mgr:pick_chunks(self(),
                                                S#state.torrent_id,
                                                S#state.piece_set,
                                                PiecesToQueue) of
                not_interested ->
                    {ok, statechange_interested(S, false)};
                none_eligible ->
                    {ok, S};
                {ok, Items} ->
                    queue_items(Items, S);
                {endgame, Items} ->
                    queue_items(Items, S#state { endgame = true })
            end
    end.

%%--------------------------------------------------------------------
%% Function: queue_items/2
%% Args:     ChunkList ::= [CompactChunk | ExplicitChunk]
%%           S         ::= #state
%%           CompactChunk ::= {PieceNumber, ChunkList}
%%           ExplicitChunk ::= {PieceNumber, Offset, Size, Ops}
%%           ChunkList ::= [{Offset, Size, Ops}]
%%           PieceNumber, Offset, Size ::= integer()
%%           Ops ::= file_operations - described elsewhere.
%% Description: Send chunk messages for each chunk we decided to queue.
%%   also add these chunks to the piece request set.
%%--------------------------------------------------------------------
queue_items(ChunkList, S) ->
    RSet = queue_items(ChunkList, S#state.send_pid, S#state.remote_request_set),
    {ok, S#state { remote_request_set = RSet }}.

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

%%--------------------------------------------------------------------
%% Function: complete_connection_setup() -> gen_server_reply()}
%% Description: Do the bookkeeping needed to set up the peer:
%%    * enable passive messaging mode on the socket.
%%    * Start the send pid
%%    * Send off the bitfield
%%--------------------------------------------------------------------
complete_connection_setup(S) ->
    {ok, SendPid} = etorrent_peer_sup:get_pid(S#state.parent, sender),
    BF = etorrent_piece_mgr:bitfield(S#state.torrent_id),
    etorrent_peer_send:bitfield(SendPid, BF),
    {noreply, S#state{send_pid = SendPid}}.

statechange_interested(S, What) ->
    etorrent_peer_send:interested(S#state.send_pid),
    S#state{local_interested = What}.

broadcast_queue_pieces(TorrentId) ->
    Peers = etorrent_peer:all(TorrentId),
    lists:foreach(fun (P) ->
                          try_queue_pieces(P#peer.pid)
                  end,
                  Peers).


broadcast_got_chunk(Chunk, TorrentId) ->
    Peers = etorrent_peer:all(TorrentId),
    lists:foreach(fun (Peer) ->
                          endgame_got_chunk(Peer#peer.pid, Chunk)
                  end,
                  Peers).

peer_have(PN, S) when S#state.piece_set =:= unknown ->
    peer_have(PN, S#state {piece_set = gb_sets:new()});
peer_have(PN, S) ->
    case etorrent_piece_mgr:valid(S#state.torrent_id, PN) of
        true ->
            Left = S#state.pieces_left - 1,
            case peer_seeds(S#state.torrent_id, Left) of
                ok ->
                    PieceSet = gb_sets:add_element(PN, S#state.piece_set),
                    NS = S#state{piece_set = PieceSet,
                                 pieces_left = Left,
                                 seeder = Left == 0},
                    case etorrent_piece_mgr:interesting(S#state.torrent_id, PN) of
                        true when S#state.local_interested =:= true ->
                            try_to_queue_up_pieces(S);
                        true when S#state.local_interested =:= false ->
                            try_to_queue_up_pieces(statechange_interested(S, true));
                        false ->
                            {ok, NS}
                    end;
                {stop, R} -> {stop, R, S}
            end;
        false ->
            {ok, {IP, Port}} = inet:peername(S#state.socket),
            etorrent_peer_mgr:enter_bad_peer(IP, Port, S#state.remote_peer_id),
            {stop, normal, S}
    end.

peer_seeds(Id, 0) ->
    ok = etorrent_peer:statechange(self(), seeder),
    [T] = etorrent_torrent:select(Id),
    case T#torrent.state of
        seeding -> {stop, normal};
        _ -> ok
    end;
peer_seeds(_Id, _N) -> ok.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
