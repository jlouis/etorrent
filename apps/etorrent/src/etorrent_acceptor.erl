%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Wait for incoming connections and accept them.
%% <p>The gen_server acceptor process timeouts immediately and
%% awaits a handshake. If the handshake comes through, it will do the
%% initial part of the handshake and then eventually spawn up a
%% process to continue the peer communication.</p>
%% <p>In other words, we only handshake here and then carry on in
%% another process tree, linked into a supervisor tree underneath the
%% right torrent.</p>
%% @end
-module(etorrent_acceptor).

-behaviour(gen_server).

-include("log.hrl").

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, { listen_socket = none,
                 our_peer_id}).

-ignore_xref([{'start_link', 1}]).
%%====================================================================

%% @doc Starts the server.
%% @end
-spec start_link(pid()) -> {ok, pid()} | ignore | {error, term()}.
start_link(OurPeerId) ->
    gen_server:start_link(?MODULE, [OurPeerId], []).

%%====================================================================

%% @private
init([OurPeerId]) ->
    {ok, ListenSocket} = etorrent_listener:get_socket(),
    {ok, #state{ listen_socket = ListenSocket,
                 our_peer_id = OurPeerId}, 0}.

%% @private
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info(timeout, S) ->
    case gen_tcp:accept(S#state.listen_socket) of
        {ok, Socket} -> handshake(Socket, S),
                        {noreply, S, 0};
        {error, closed}       -> {noreply, S, 0};
        {error, econnaborted} -> {noreply, S, 0};
        {error, enotconn}     -> {noreply, S, 0};
        {error, E}            -> {stop, E, S}
    end.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------

handshake(Socket, S) ->
    case etorrent_proto_wire:receive_handshake(Socket) of
        {ok, Caps, InfoHash, PeerId} ->
            lookup_infohash(Socket, Caps, InfoHash, PeerId, S);
        {error, _Reason} ->
            gen_tcp:close(Socket),
            ok
    end.

lookup_infohash(Socket, Caps, InfoHash, PeerId, S) ->
    case etorrent_table:get_torrent({infohash, InfoHash}) of
	{value, _} ->
	    start_peer(Socket, Caps, PeerId, InfoHash, S);
	not_found ->
	    gen_tcp:close(Socket),
	    ok
    end.

start_peer(Socket, Caps, PeerId, InfoHash, S) ->
    {ok, {Address, Port}} = inet:peername(Socket),
    case new_incoming_peer(Socket, Caps, Address, Port, InfoHash, PeerId, S) of
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
            ?INFO([peer_id_is_bad, PeerId]),
            gen_tcp:close(Socket),
            ok
    end.

new_incoming_peer(_Socket, _Caps, _IP, _Port, _InfoHash, PeerId,
    #state { our_peer_id = Our_Peer_Id }) when Our_Peer_Id == PeerId ->
        connect_to_ourselves;
new_incoming_peer(Socket, Caps, IP, Port, InfoHash, _PeerId, S) ->
    {value, PL} = etorrent_table:get_torrent({infohash, InfoHash}),
    case etorrent_peer_mgr:is_bad_peer(IP, Port) of
        true ->
            bad_peer;
        false ->
            case etorrent_table:connected_peer(IP, Port, proplists:get_value(id, PL)) of
                true -> already_connected;
                false -> start_new_incoming_peer(Socket, Caps, IP, Port, InfoHash, S)
            end
    end.


start_new_incoming_peer(Socket, Caps, IP, Port, InfoHash, S) ->
    case etorrent_counters:slots_left() of
        {value, 0} -> already_enough_connections;
        {value, K} when is_integer(K) ->
	    {value, PL} = etorrent_table:get_torrent({infohash, InfoHash}),
            etorrent_torrent_sup:add_peer(
	      S#state.our_peer_id,
	      InfoHash,
	      proplists:get_value(id, PL),
	      {IP, Port},
	      Caps,
	      Socket)
    end.

