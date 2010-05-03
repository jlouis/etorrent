%%%-------------------------------------------------------------------
%%% File    : etorrent_t_peer_send.erl
%%% Author  : Jesper Louis Andersen
%%% License : See COPYING
%%% Description : Send out events to a foreign socket.
%%%
%%% Created : 27 Jan 2007 by
%%%   Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_t_peer_send).

-include("etorrent_mnesia_table.hrl").
-include("etorrent_rate.hrl").

-behaviour(gen_server).

%% API
-export([start_link/5,
         stop/1,
         check_choke/1,

         local_request/2, remote_request/4, cancel/4,
         choke/1, unchoke/1, have/2,

         not_interested/1, interested/1,
         bitfield/2]).

%% gen_server callbacks
-export([init/1, handle_info/2, terminate/2, code_change/3,
         handle_call/3, handle_cast/2]).

-record(state, {socket = none,
                requests = none,

                fast_extension = false,

                rate = none,
                choke = true,
                interested = false, % Are we interested in the peer?
                timer = none,
                rate_timer = none,
                parent = none,
                piece_cache = none,
                torrent_id = none,
                file_system_pid = none}).

-define(DEFAULT_KEEP_ALIVE_INTERVAL, 120*1000). % From proto. spec.
-define(MAX_REQUESTS, 1024). % Maximal number of requests a peer may make.
%%====================================================================
%% API
%%====================================================================
start_link(Socket, FilesystemPid, TorrentId, FastExtension, RecvPid) ->
    gen_server:start_link(?MODULE,
                          [Socket, FilesystemPid, TorrentId, FastExtension,
                           RecvPid], []).

%%--------------------------------------------------------------------
%% Func: remote_request(Pid, Index, Offset, Len)
%% Description: The remote end (ie, the peer) requested a chunk
%%  {Index, Offset, Len}
%%--------------------------------------------------------------------
remote_request(Pid, Index, Offset, Len) ->
    gen_server:cast(Pid, {remote_request, Index, Offset, Len}).

%%--------------------------------------------------------------------
%% Func: local_request(Pid, Index, Offset, Len)
%% Description: We request a piece from the peer: {Index, Offset, Len}
%%--------------------------------------------------------------------
local_request(Pid, {Index, Offset, Size}) ->
    gen_server:cast(Pid, {local_request, {Index, Offset, Size}}).

%%--------------------------------------------------------------------
%% Func: cancel(Pid, Index, Offset, Len)
%% Description: Cancel the {Index, Offset, Len} at the peer.
%%--------------------------------------------------------------------
cancel(Pid, Index, Offset, Len) ->
    gen_server:cast(Pid, {cancel, Index, Offset, Len}).

%%--------------------------------------------------------------------
%% Func: choke(Pid)
%% Description: Choke the peer.
%%--------------------------------------------------------------------
choke(Pid) ->
    gen_server:cast(Pid, choke).

%%--------------------------------------------------------------------
%% Func: unchoke(Pid)
%% Description: Unchoke the peer.
%%--------------------------------------------------------------------
unchoke(Pid) ->
    gen_server:cast(Pid, unchoke).

check_choke(Pid) -> gen_server:cast(Pid, check_choke).

%%--------------------------------------------------------------------
%% Func: not_interested(Pid)
%% Description: Tell the peer we are not interested in him anymore
%%--------------------------------------------------------------------
not_interested(Pid) ->
    gen_server:cast(Pid, not_interested).

interested(Pid) ->
    gen_server:cast(Pid, interested).

%%--------------------------------------------------------------------
%% Func: have(Pid, PieceNumber)
%% Description: Tell the peer we have the piece PieceNumber
%%--------------------------------------------------------------------
have(Pid, PieceNumber) ->
    gen_server:cast(Pid, {have, PieceNumber}).

bitfield(Pid, BitField) ->
    gen_server:cast(Pid, {bitfield, BitField}).


%%--------------------------------------------------------------------
%% Func: stop(Pid)
%% Description: Tell the send process to stop the communication.
%%--------------------------------------------------------------------
stop(Pid) ->
    gen_server:cast(Pid, stop).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Socket, FilesystemPid, TorrentId, FastExtension, Parent]) ->
    process_flag(trap_exit, true),
    {ok, TRef} = timer:send_interval(?DEFAULT_KEEP_ALIVE_INTERVAL, self(), tick),
    {ok, Tref2} = timer:send_interval(?RATE_UPDATE, self(), rate_update),
    {ok,
     #state{socket = Socket,
            timer = TRef,
            rate_timer = Tref2,
            requests = queue:new(),
            rate = etorrent_rate:init(),
            parent = Parent,
            torrent_id = TorrentId,
            fast_extension = FastExtension,
            file_system_pid = FilesystemPid},
     0}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_info(tick, S) ->
    send_message(keep_alive, S, 0);
handle_info(rate_update, S) ->
    Rate = etorrent_rate:update(S#state.rate, 0),
    ok = etorrent_rate_mgr:send_rate(S#state.torrent_id,
                                     S#state.parent,
                                     Rate#peer_rate.rate,
                                     0),
    {noreply, S#state { rate = Rate }};
handle_info(timeout, S)
  when S#state.choke =:= true andalso S#state.piece_cache =:= none ->
    garbage_collect(),
    {noreply, S};
handle_info(timeout, S) when S#state.choke =:= true ->
    {noreply, S};
handle_info(timeout, S) when S#state.choke =:= false ->
    case queue:out(S#state.requests) of
        {empty, _} ->
            {noreply, S};
        {{value, {Index, Offset, Len}}, NewQ} ->
            send_piece(Index, Offset, Len, S#state { requests = NewQ } )
    end;
handle_info(Msg, S) ->
    error_logger:info_report([got_unknown_message, Msg, S]),
    {stop, {unknown_msg, Msg}}.

handle_cast(choke, S) ->
    perform_choke(S);
handle_cast(unchoke, S) when S#state.choke == false ->
    {noreply, S, 0};
handle_cast(unchoke, S) when S#state.choke == true ->
    ok = etorrent_rate_mgr:local_unchoke(S#state.torrent_id, S#state.parent),
    send_message(unchoke, S#state{choke = false});
handle_cast(check_choke, S) when S#state.choke =:= true ->
    {noreply, S, 0};
handle_cast(check_choke, S) when S#state.choke =:= false ->
    ok = etorrent_choker:perform_rechoke(),
    {noreply, S, 0};
handle_cast({bitfield, BF}, S) ->
    send_message({bitfield, BF}, S);
handle_cast(not_interested, S) when S#state.interested =:= false ->
    {noreply, S, 0};
handle_cast(not_interested, S) when S#state.interested =:= true ->
    send_message(not_interested, S#state { interested = false });
handle_cast(interested, S) when S#state.interested =:= true ->
    {noreply, S, 0};
handle_cast(interested, S) when S#state.interested =:= false ->
    send_message(interested, S#state { interested = true });
handle_cast({have, Pn}, S) ->
    send_message({have, Pn}, S);
handle_cast({local_request, {Index, Offset, Size}}, S) ->
    send_message({request, Index, Offset, Size}, S);
handle_cast({remote_request, Idx, Offset, Len}, S)
  when S#state.fast_extension =:= true, S#state.choke == true ->
    send_message({reject_request, Idx, Offset, Len}, S, 0);
handle_cast({remote_request, _Index, _Offset, _Len}, S)
  when S#state.choke == true ->
    {noreply, S, 0};
handle_cast({remote_request, Index, Offset, Len}, S)
  when S#state.choke == false ->
    case queue:len(S#state.requests) > ?MAX_REQUESTS of
        true when S#state.fast_extension =:= true ->
            send_message({reject_request, Index, Offset, Len}, S, 0);
        true ->
            {stop, max_queue_len_exceeded, S};
        false ->
            NQ = queue:in({Index, Offset, Len}, S#state.requests),
            {noreply, S#state{requests = NQ}, 0}
    end;
handle_cast({cancel, Idx, Offset, Len}, S) when S#state.fast_extension =:= true ->
    try
        NQ = etorrent_utils:queue_remove_check({Idx, Offset, Len},
                                               S#state.requests),
        {noreply, S#state { requests = NQ}, 0}
    catch
        exit:badmatch -> {stop, normal, S}
    end;
handle_cast({cancel, Index, OffSet, Len}, S) ->
    NQ = etorrent_utils:queue_remove({Index, OffSet, Len}, S#state.requests),
    {noreply, S#state{requests = NQ}, 0};
handle_cast(stop, S) ->
    {stop, normal, S}.


%% Terminating normally means we should inform our recv pair
terminate(_Reason, S) ->
    _ = timer:cancel(S#state.timer),
    _ = timer:cancel(S#state.rate_timer),
    ok.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: send_piece_message/2
%% Description: Send the message Msg and handle an eventual connection
%%   close gracefully.
%%--------------------------------------------------------------------
send_piece_message(Msg, S, Timeout) ->
    case etorrent_peer_communication:send_message(S#state.rate, S#state.socket, Msg) of
        {ok, R, Amount} ->
            ok = etorrent_rate_mgr:send_rate(S#state.torrent_id,
                                             S#state.parent,
                                             R#peer_rate.rate,
                                             Amount),
            {noreply, S#state { rate = R }, Timeout};
        {{error, closed}, R, _Amount} ->
            {stop, normal, S#state { rate = R}}
    end.

send_piece(Index, Offset, Len, S) ->
    case S#state.piece_cache of
        {I, Binary} when I == Index ->
            <<_Skip:Offset/binary, Data:Len/binary, _R/binary>> = Binary,
            Msg = {piece, Index, Offset, Data},
            %% Track uploaded size for torrent (for the tracker)
            ok = etorrent_torrent:statechange(S#state.torrent_id,
                                              {add_upload, Len}),
            %% Track the amount uploaded by this peer.

            send_piece_message(Msg, S, 0);
        %% Update cache and try again...
        {I, _Binary} when I /= Index ->
            NS = load_piece(Index, S),
            send_piece(Index, Offset, Len, NS);
        none ->
            NS = load_piece(Index, S),
            send_piece(Index, Offset, Len, NS)
    end.

load_piece(Index, S) ->
    {ok, Piece} = etorrent_fs:read_piece(S#state.file_system_pid, Index),
    S#state{piece_cache = {Index, Piece}}.

send_message(Msg, S) ->
    send_message(Msg, S, 0).

send_message(Msg, S, Timeout) ->
    case send(Msg, S) of
        {ok, NS} -> {noreply, NS, Timeout};
        {error, closed, NS} -> {stop, normal, NS};
        {error, ebadf, NS} -> {stop, normal, NS}
    end.

send(Msg, S) ->
    case etorrent_peer_communication:send_message(S#state.rate, S#state.socket, Msg) of
        {ok, Rate, Amount} ->
            ok = etorrent_rate_mgr:send_rate(
                   S#state.torrent_id,
                   S#state.parent,
                   Rate#peer_rate.rate,
                   Amount),
            {ok, S#state { rate = Rate}};
        {{error, E}, R, _Amount} ->
            {error, E, S#state { rate = R }}
    end.


perform_choke(S = #state { fast_extension = FX, choke = C}) ->
    case {FX, C} of
        {false, true} -> {noreply, S, 0};
        {false, false} ->
            ok = local_choke(S),
            send_message(choke, S#state{choke = true, requests = queue:new(),
                                        piece_cache = none});
        {true, true} -> {noreply, S, 0};
        {true, false} ->
            local_choke(S),
            {ok, NS} = send(choke, S),
            FS = empty_requests(NS),
            {noreply, FS, 0}
    end.

empty_requests(S) ->
    empty_requests(queue:out(S#state.requests), S).

empty_requests({empty, Q}, S) ->
    S#state { requests = Q , piece_cache = none};
empty_requests({{value, {Index, Offset, Len}}, Next}, S) ->
    {ok, NS} = send({reject_request, Index, Offset, Len}, S),
    empty_requests(queue:out(Next), NS).

local_choke(S) ->
    etorrent_rate_mgr:local_choke(S#state.torrent_id,
                                  S#state.parent).
