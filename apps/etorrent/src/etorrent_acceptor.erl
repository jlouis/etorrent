%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Accept new connections from the network.
%% <p>This function will accept a new connection from the network and
%% then perform the initial part of the handshake. If successful, the
%% process will spawn a real controller process and hand off the
%% socket to that process.</p>
%% @end
-module(etorrent_acceptor).

-behaviour(gen_server).

-include("log.hrl").

%% API
-export([start_link/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, { listen_socket = none,
                 our_peer_id}).

%% @doc Starts the server.
%% @end
%% @todo Type of listen socket!
-spec start_link(pid(), term()) -> {ok, pid()} | ignore | {error, term()}.
start_link(OurPeerId, LSock) ->
    gen_server:start_link(?MODULE, [OurPeerId, LSock], []).

%%====================================================================

%% @private
init([PeerId, LSock]) ->
    {ok, #state{ listen_socket = LSock,
                 our_peer_id = PeerId }, 0}.

%% @private
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info(timeout, #state { our_peer_id = PeerId } = S) ->
    case gen_tcp:accept(S#state.listen_socket) of
        {ok, Socket} ->
	    {ok, _Pid} = etorrent_listen_sup:start_child(),
	    handshake(Socket, PeerId);
        {error, closed}       -> ok;
        {error, econnaborted} -> ok;
        {error, enotconn}     -> ok;
        {error, E}            -> ?WARN([{error, E}]), ok
    end,
    {stop, normal, S}.
    end.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

handshake(Socket, PeerId) ->
    case etorrent_proto_wire:receive_handshake(Socket) of
        {ok, Caps, InfoHash, HisPeerId} ->
            lookup_infohash(Socket, Caps, InfoHash, HisPeerId, PeerId);
        {error, _Reason} ->
            gen_tcp:close(Socket),
            ok
    end.

lookup_infohash(Socket, Caps, InfoHash, HisPeerId, OurPeerId) ->
    case etorrent_table:get_torrent({infohash, InfoHash}) of
	{value, _} ->
	    start_peer(Socket, Caps, HisPeerId, InfoHash, OurPeerId);
	not_found ->
	    gen_tcp:close(Socket),
	    ok
    end.

start_peer(Socket, Caps, HisPeerId, InfoHash, OurPeerId) ->
    {ok, {Address, Port}} = inet:peername(Socket),
    case new_incoming_peer(Socket, Caps, Address, Port, InfoHash, HisPeerId, OurPeerId) of
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
            ?INFO([peer_id_is_bad, HisPeerId]),
            gen_tcp:close(Socket),
            ok
    end.

new_incoming_peer(_Socket, _Caps, _IP, _Port, _InfoHash, PeerId, PeerId) ->
        connect_to_ourselves;
new_incoming_peer(Socket, Caps, IP, Port, InfoHash, _HisPeerId, OurPeerId) ->
    {value, PL} = etorrent_table:get_torrent({infohash, InfoHash}),
    case etorrent_peer_mgr:is_bad_peer(IP, Port) of
        true ->
            bad_peer;
        false ->
            case etorrent_table:connected_peer(IP, Port, proplists:get_value(id, PL)) of
                true -> already_connected;
                false -> start_new_incoming_peer(Socket, Caps, IP, Port, InfoHash, OurPeerId)
            end
    end.


start_new_incoming_peer(Socket, Caps, IP, Port, InfoHash, OurPeerId) ->
    case etorrent_counters:slots_left() of
        {value, 0} -> already_enough_connections;
        {value, K} when is_integer(K) ->
	    {value, PL} = etorrent_table:get_torrent({infohash, InfoHash}),
            etorrent_t_sup:add_peer(
	      OurPeerId,
	      InfoHash,
	      proplists:get_value(id, PL),
	      {IP, Port},
	      Caps,
	      Socket)
    end.

