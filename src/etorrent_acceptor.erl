%%%-------------------------------------------------------------------
%%% File    : acceptor.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% Description : Accept new connections from the network.
%%%
%%% Created : 30 Jul 2007 by Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_acceptor).

-behaviour(gen_server).

-include("etorrent_mnesia_table.hrl").

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, { listen_socket = none,
                 our_peer_id}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link(OurPeerId) -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server.
%%--------------------------------------------------------------------
start_link(OurPeerId) ->
    gen_server:start_link(?MODULE, [OurPeerId], []).

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
init([OurPeerId]) ->
    {ok, ListenSocket} = etorrent_listener:get_socket(),
    {ok, #state{ listen_socket = ListenSocket,
                 our_peer_id = OurPeerId}, 0}.

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
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(timeout, S) ->
    case gen_tcp:accept(S#state.listen_socket) of
        {ok, Socket} -> handshake(Socket, S),
                        {noreply, S, 0};
        {error, closed}       -> {noreply, S, 0};
        {error, econnaborted} -> {noreply, S, 0};
        {error, enotconn}     -> {noreply, S, 0};
        {error, E}            -> {stop, E, S}
    end.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

handshake(Socket, S) ->
    case etorrent_proto_wire:receive_handshake(Socket) of
        {ok, ReservedBytes, InfoHash, PeerId} ->
            lookup_infohash(Socket, ReservedBytes, InfoHash, PeerId, S);
        {error, _Reason} ->
            gen_tcp:close(Socket),
            ok
    end.

lookup_infohash(Socket, ReservedBytes, InfoHash, PeerId, S) ->
    case etorrent_tracking_map:select({infohash, InfoHash}) of
        {atomic, [#tracking_map { _ = _}]} ->
            start_peer(Socket, ReservedBytes, PeerId, InfoHash, S);
        {atomic, []} ->
            gen_tcp:close(Socket),
            ok
    end.

start_peer(Socket, _ReservedBytes, PeerId, InfoHash, S) ->
    {ok, {Address, Port}} = inet:peername(Socket),
    case new_incoming_peer(Socket, Address, Port, InfoHash, PeerId, S) of
        {ok, RPid, CPid} ->
            case gen_tcp:controlling_process(Socket, RPid) of
                ok -> etorrent_peer_control:initialize(CPid, incoming),
                      ok;
                {error, enotconn} ->
                    etorrent_peer_control:stop(CPid),
                    ok
            end;
        already_enough_connections -> ok;
        already_connected -> ok;
        connect_to_ourselves ->
            gen_tcp:close(Socket),
            ok;
        bad_peer ->
            error_logger:info_report([peer_id_is_bad, PeerId]),
            gen_tcp:close(Socket),
            ok
    end.

new_incoming_peer(_Socket, _IP, _Port, _InfoHash, PeerId, S)
            when S#state.our_peer_id == PeerId ->
    connect_to_ourselves;
new_incoming_peer(Socket, IP, Port, InfoHash, _PeerId, S) ->
    {atomic, [TM]} = etorrent_tracking_map:select({infohash, InfoHash}),
    case etorrent_peer_mgr:is_bad_peer(IP, Port) of
        true ->
            bad_peer;
        false ->
            case etorrent_peer:connected(IP, Port, TM#tracking_map.id) of
                true -> already_connected;
                false -> start_new_incoming_peer(Socket, IP, Port, InfoHash, S)
            end
    end.


start_new_incoming_peer(Socket, IP, Port, InfoHash, S) ->
    case etorrent_counters:obtain_peer_slot() of
        full -> already_enough_connections;
        ok ->
            {atomic, [T]} = etorrent_tracking_map:select({infohash, InfoHash}),
            try etorrent_t_sup:add_peer(
                  T#tracking_map.supervisor_pid,
                  S#state.our_peer_id,
                  InfoHash,
                  T#tracking_map.id,
                  {IP, Port},
                  Socket)
            catch
                _ -> etorrent_counters:release_peer_slot()
            end
    end.

