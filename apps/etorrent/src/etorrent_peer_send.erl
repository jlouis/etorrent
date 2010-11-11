
%%%-------------------------------------------------------------------
%%% File    : etorrent_peer_send.erl
%%% Author  : Jesper Louis Andersen
%%% License : See COPYING
%%% Description : Send out events to a foreign socket.
%%%
%%% Created : 27 Jan 2007 by
%%%   Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_peer_send).

-include("etorrent_rate.hrl").
-include("log.hrl").

-behaviour(gen_server).

-ignore_xref([{'start_link', 3}]).
%% Apart from standard gen_server things, the main idea of this module is
%% to serve as a mediator for the peer in the send direction. Precisely,
%% we have a message we can send to the process, for each of the possible
%% messages one can send to a peer.
-export([start_link/3,
         check_choke/1,

         go_fast/1,
         go_slow/1,

         local_request/2, remote_request/4, cancel/4,
         choke/1, unchoke/1, have/2,
         not_interested/1, interested/1,
	 extended_msg/1,
         bitfield/2]).

%% gen_server callbacks
-export([init/1, handle_info/2, terminate/2, code_change/3,
         handle_call/3, handle_cast/2]).
-ignore_xref({start_link, 5}).

-type( mode() :: 'fast' | 'slow').

-record(state, {socket = none,
                requests = none,

                fast_extension = false,

                mode = slow :: mode(),

                controller = none,
                rate = none,
                choke = true,
                interested = false, % Are we interested in the peer?
                parent = none,
                torrent_id = none,
                file_system_pid = none}).

-define(DEFAULT_KEEP_ALIVE_INTERVAL, 120*1000). % From proto. spec.
-define(MAX_REQUESTS, 1024). % Maximal number of requests a peer may make.

%%====================================================================
%% API
%%====================================================================
-spec start_link(port(), integer(), boolean()) ->
    ignore | {ok, pid()} | {error, any()}.
start_link(Socket, TorrentId, FastExtension) ->
    gen_server:start_link(?MODULE,
                          [Socket, TorrentId, FastExtension], []).

%%--------------------------------------------------------------------
%% Func: remote_request(Pid, Index, Offset, Len)
%% Description: The remote end (ie, the peer) requested a chunk
%%  {Index, Offset, Len}
%%--------------------------------------------------------------------
-spec remote_request(pid(), integer(), integer(), integer()) -> ok.
remote_request(Pid, Index, Offset, Len) ->
    gen_server:cast(Pid, {remote_request, Index, Offset, Len}).

%%--------------------------------------------------------------------
%% Func: local_request(Pid, Index, Offset, Len)
%% Description: We request a piece from the peer: {Index, Offset, Len}
%%--------------------------------------------------------------------
-spec local_request(pid(), {integer(), integer(), integer()}) -> ok.
local_request(Pid, {Index, Offset, Size}) ->
    gen_server:cast(Pid, {local_request, {Index, Offset, Size}}).

%%--------------------------------------------------------------------
%% Func: cancel(Pid, Index, Offset, Len)
%% Description: Cancel the {Index, Offset, Len} at the peer.
%%--------------------------------------------------------------------
-spec cancel(pid(), integer(), integer(), integer()) -> ok.
cancel(Pid, Index, Offset, Len) ->
    gen_server:cast(Pid, {cancel, Index, Offset, Len}).

%%--------------------------------------------------------------------
%% Func: choke(Pid)
%% Description: Choke the peer.
%%--------------------------------------------------------------------
-spec choke(pid()) -> ok.
choke(Pid) ->
    gen_server:cast(Pid, choke).

%%--------------------------------------------------------------------
%% Func: unchoke(Pid)
%% Description: Unchoke the peer.
%%--------------------------------------------------------------------
-spec unchoke(pid()) -> ok.
unchoke(Pid) ->
    gen_server:cast(Pid, unchoke).

%% This call is used whenever we want to check the choke state of the peer.
%% If it is true, we perform a rechoke request. It is probably the wrong
%% place to issue the rechoke request. Rather, it would be better if a
%% control process does this.
-spec check_choke(pid()) -> ok.
check_choke(Pid) ->
    gen_server:cast(Pid, check_choke).

%%--------------------------------------------------------------------
%% Func: not_interested(Pid)
%% Description: Tell the peer we are not interested in him anymore
%%--------------------------------------------------------------------
-spec not_interested(pid()) -> ok.
not_interested(Pid) ->
    gen_server:cast(Pid, not_interested).

%% Tell the peer we are interested in him/her.
-spec interested(pid()) -> ok.
interested(Pid) ->
    gen_server:cast(Pid, interested).

%%--------------------------------------------------------------------
%% Func: have(Pid, PieceNumber)
%% Description: Tell the peer we have the piece PieceNumber
%%--------------------------------------------------------------------
-spec have(pid(), integer()) -> ok.
have(Pid, PieceNumber) ->
    gen_server:cast(Pid, {have, PieceNumber}).

%% Send a bitfield message to the peer
-spec bitfield(pid(), binary()) -> ok. %% This should be checked
bitfield(Pid, BitField) ->
    gen_server:cast(Pid, {bitfield, BitField}).

-spec extended_msg(pid()) -> ok.
extended_msg(Pid) ->
    gen_server:cast(Pid, extended_msg).

%% Request that we enable fast messaging (port is active and we get messages).
-spec go_fast(pid()) -> ok.
go_fast(Pid) ->
    gen_server:cast(Pid, {go_fast, self()}).

%% Request that we enable slow messaging (manual handling of packets, port is passive)
-spec go_slow(pid()) -> ok.
go_slow(Pid) ->
    gen_server:cast(Pid, {go_slow, self()}).


%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------


%% Send off a piece message
send_piece(Index, Offset, Len, S) ->
    {ok, PieceData} =
        etorrent_fs:read_chunk(S#state.file_system_pid, Index, Offset, Len),
    Msg = {piece, Index, Offset, PieceData},
    ok = etorrent_torrent:statechange(S#state.torrent_id,
                                        [{add_upload, Len}]),
    send_message(Msg, S).

send_message(Msg, S) ->
    send_message(Msg, S, 0).

%% TODO: Think about the stop messages here. They are definitely wrong.
send_message(Msg, S, Timeout) ->
    case send(Msg, S) of
        {ok, NS} -> {noreply, NS, Timeout};
        {error, closed, NS} -> {stop, normal, NS};
        {error, ebadf, NS} -> {stop, normal, NS}
    end.

send(Msg, #state { torrent_id = Id} = S) ->
    case etorrent_proto_wire:send_msg(S#state.socket, Msg, S#state.mode) of
        {ok, Sz} ->
            NR = etorrent_rate:update(S#state.rate, Sz),
            ok = etorrent_torrent:statechange(Id, [{add_upload, Sz}]),
            {ok, S#state { rate = NR}};
        {{error, E}, _Amount} ->
            {error, E, S}
    end.

perform_choke(#state { fast_extension = true} = S) ->
    perform_fast_ext_choke(S);
perform_choke(#state { choke = true } = S) ->
    {noreply, S, 0};
perform_choke(S) ->
    local_choke(S),
    send_message(choke, S#state{choke = true, requests = queue:new() }).

perform_fast_ext_choke(#state { choke = true } = S) ->
    {noreply, S, 0};
perform_fast_ext_choke(S) ->
     local_choke(S),
     {ok, NS} = send(choke, S),
     FS = empty_requests(NS),
     {noreply, FS, 0}.

empty_requests(S) ->
    empty_requests(queue:out(S#state.requests), S).

empty_requests({empty, Q}, S) ->
    S#state { requests = Q };
empty_requests({{value, {Index, Offset, Len}}, Next}, S) ->
    {ok, NS} = send({reject_request, Index, Offset, Len}, S),
    empty_requests(queue:out(Next), NS).

local_choke(S) ->
    etorrent_rate_mgr:local_choke(S#state.torrent_id,
                                  S#state.parent).

%% Unused callbacks
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Socket, TorrentId, FastExtension]) ->
    erlang:send_after(?DEFAULT_KEEP_ALIVE_INTERVAL, self(), tick),
    erlang:send_after(?RATE_UPDATE, self(), rate_update),
    gproc:add_local_name({peer, Socket, sender}),
    FS = gproc:lookup_local_name({torrent, TorrentId, fs}),
    %% This may fail, but I want to check it
    {ok,
     #state{socket = Socket,
            requests = queue:new(),
            rate = etorrent_rate:init(),
            parent = {non_inited, foo},
            controller = none,
            torrent_id = TorrentId,
            fast_extension = FastExtension,
            file_system_pid = FS},
     0}. %% Quickly enter a timeout.


%% Whenever a tick is hit, we send out a keep alive message on the line.
handle_info(tick, S) ->
    erlang:send_after(?DEFAULT_KEEP_ALIVE_INTERVAL, self(), tick),
    send_message(keep_alive, S, 0);

%% When we are requested to update our rate, we do it here.
handle_info(rate_update, S) ->
    erlang:send_after(?RATE_UPDATE, self(), rate_update),
    Rate = etorrent_rate:update(S#state.rate, 0),
    ok = etorrent_rate_mgr:send_rate(S#state.torrent_id,
                                     S#state.parent,
                                     Rate#peer_rate.rate),
    {noreply, S#state { rate = Rate }};

%% Different timeouts.
%% When we are choking the peer and the piece cache is empty, garbage_collect() to reclaim
%% space quickly rather than waiting for it to happen.
%% @todo Consider if this can be simplified. It looks wrong here.
handle_info(timeout, #state{ parent = {non_inited, _},
			     socket = Sock } = S) ->
    RecvPid = gproc:lookup_local_name({peer, Sock, receiver}),
    {noreply, S#state { parent = RecvPid }, 0};
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

%% Handle requests to choke and unchoke. If we are already choking the peer,
%% there is no reason to send the message again.
handle_cast(choke, S) -> perform_choke(S);
handle_cast(unchoke, #state { choke = false } = S) -> {noreply, S, 0};
handle_cast(unchoke,
        #state { choke = true, torrent_id = Torrent_Id, parent = Parent } = S) ->
    ok = etorrent_rate_mgr:local_unchoke(Torrent_Id, Parent),
    send_message(unchoke, S#state{choke = false});

%% A request to check the current choke state and ask for a rechoking
handle_cast(check_choke, #state { choke = true } = S) ->
    {noreply, S, 0};
handle_cast(check_choke, #state { choke = false } = S) ->
    ok = etorrent_choker:perform_rechoke(),
    {noreply, S, 0};

%% Regular messages. We just send them onwards on the wire.
handle_cast({bitfield, BF}, S) ->
    send_message({bitfield, BF}, S);
handle_cast(extended_msg, S) ->
    send_message({extended, 0, etorrent_proto_wire:extended_msg_contents()}, S);
handle_cast(not_interested, #state { interested = false} = S) ->
    {noreply, S, 0};
handle_cast(not_interested, #state { interested = true } = S) ->
    send_message(not_interested, S#state { interested = false });
handle_cast(interested, #state { interested = true } = S) ->
    {noreply, S, 0};
handle_cast(interested, #state { interested = false } = S) ->
    send_message(interested, S#state { interested = true });
handle_cast({have, Pn}, S) ->
    send_message({have, Pn}, S);

%% Cancels are handled specially when the fast extension is enabled.
handle_cast({cancel, Idx, Offset, Len},
        #state { fast_extension = true, requests = Requests} = S) ->
    try
        NQ = etorrent_utils:queue_remove_check({Idx, Offset, Len},
                                               Requests),
        {noreply, S#state { requests = NQ}, 0}
    catch
        exit:badmatch -> {stop, normal, S}
    end;
handle_cast({cancel, Index, OffSet, Len}, S) ->
    NQ = etorrent_utils:queue_remove({Index, OffSet, Len}, S#state.requests),
    {noreply, S#state{requests = NQ}, 0};

handle_cast({local_request, {Index, Offset, Size}}, S) ->
    send_message({request, Index, Offset, Size}, S);
handle_cast({remote_request, Idx, Offset, Len},
    #state { fast_extension = true, choke = true } = S) ->
        send_message({reject_request, Idx, Offset, Len}, S, 0);
handle_cast({remote_request, _Index, _Offset, _Len}, #state { choke = true } = S) ->
    {noreply, S, 0};
handle_cast({remote_request, Index, Offset, Len},
            #state { choke = false, fast_extension = FastExtension,
                     requests = Reqs} = S) ->
    case queue:len(Reqs) > ?MAX_REQUESTS of
        true when FastExtension == true ->
            send_message({reject_request, Index, Offset, Len}, S, 0);
        true ->
            {stop, max_queue_len_exceeded, S};
        false ->
            NQ = queue:in({Index, Offset, Len}, S#state.requests),
            {noreply, S#state{requests = NQ}, 0}
    end;
handle_cast({go_fast, Pid}, S) ->
    ok = etorrent_peer_recv:cb_go_fast(Pid),
    {noreply, S#state { mode = fast }};
handle_cast({go_slow, Pid}, S) ->
    ok = etorrent_peer_recv:cb_go_slow(Pid),
    {noreply, S#state { mode = slow }};
handle_cast(_Msg, S) ->
    {noreply, S}.

terminate(_Reason, _S) ->
    ok.
