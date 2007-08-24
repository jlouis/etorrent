%%%-------------------------------------------------------------------
%%% File    : peer_communication.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus>
%%% License : See COPYING
%%% Description : Various pieces of the peer protocol that takes a bit to
%%%   handle.
%%%
%%% Created : 26 Jan 2007 by Jesper Louis Andersen <jlouis@succubus>
%%%-------------------------------------------------------------------
-module(etorrent_peer_communication).

%% API
-export([initiate_handshake/3, recieve_handshake/1,
	 complete_handshake_header/3]).
-export([send_message/2, recv_message/1,
	 construct_bitfield/2, destruct_bitfield/2]).

-define(DEFAULT_HANDSHAKE_TIMEOUT, 120000).
-define(HANDSHAKE_SIZE, 68).
-define(PROTOCOL_STRING, "BitTorrent protocol").
-define(RESERVED_BYTES, 0:64/big).

%% Packet types
-define(CHOKE, 0:8).
-define(UNCHOKE, 1:8).
-define(INTERESTED, 2:8).
-define(NOT_INTERESTED, 3:8).
-define(HAVE, 4:8).
-define(BITFIELD, 5:8).
-define(REQUEST, 6:8).
-define(PIECE, 7:8).
-define(CANCEL, 8:8).
-define(PORT, 9:8).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: recv_message(Message) -> keep_alive | choke | unchoke |
%%   interested | not_interested | {have, integer()} | ...
%% Description: Receive a message from a peer and decode it
%%--------------------------------------------------------------------
recv_message(Message) ->
    case Message of
	<<>> ->
	    keep_alive;
	<<?CHOKE>> ->
	    choke;
	<<?UNCHOKE>> ->
	    unchoke;
	<<?INTERESTED>> ->
	    interested;
	<<?NOT_INTERESTED>> ->
	    not_interested;
	<<?HAVE, PieceNum:32/big>> ->
	    {have, PieceNum};
	<<?BITFIELD, BitField/binary>> ->
	    {bitfield, BitField};
	<<?REQUEST, Index:32/big, Begin:32/big, Len:32/big>> ->
	    {request, Index, Begin, Len};
	<<?PIECE, Index:32/big, Begin:32/big, Data/binary>> ->
	    {piece, Index, Begin, Data};
	<<?CANCEL, Index:32/big, Begin:32/big, Len:32/big>> ->
	    {cancel, Index, Begin, Len};
	<<?PORT, Port:16/big>> ->
	    {port, Port}
    end.

%%--------------------------------------------------------------------
%% Function: send_message(Socket, Message)
%% Description: Send a message on a socket
%%--------------------------------------------------------------------
send_message(Socket, Message) ->
    Datagram =
	case Message of
	    keep_alive ->
		<<>>;
	    choke ->
		<<?CHOKE>>;
	    unchoke ->
		<<?UNCHOKE>>;
	    interested ->
		<<?INTERESTED>>;
	    not_interested ->
		<<?NOT_INTERESTED>>;
	    {have, PieceNum} ->
		<<?HAVE, PieceNum:32/big>>;
	    {bitfield, BitField} ->
		<<?BITFIELD, BitField/binary>>;
	    {request, Index, Begin, Len} ->
		<<?REQUEST, Index:32/big, Begin:32/big, Len:32/big>>;
	    {piece, Index, Begin, Data} ->
		<<?PIECE,
		 Index:32/big, Begin:32/big, Data/binary>>;
	    {cancel, Index, Begin, Len} ->
		<<?CANCEL, Index:32/big, Begin:32/big, Len:32/big>>;
	    {port, PortNum} ->
		<<?PORT, PortNum:16/big>>
        end,
    gen_tcp:send(Socket, Datagram).

%%--------------------------------------------------------------------
%% Function: recieve_handshake(Socket) -> {ok, protocol_version,
%%                                             info_hash(),
%%                                             remote_peer_id()} |
%%                                        {error, Reason}
%% Description: Recieve a handshake from another peer. In the recieve,
%%  we don't send the info_hash, but expect the initiator to send what
%%  he thinks is the correct hash. For the return value, see the
%%  function recieve_header()
%%--------------------------------------------------------------------
recieve_handshake(Socket) ->
    Header = build_peer_protocol_header(),
    ok = gen_tcp:send(Socket, Header),
    receive_header(Socket).

%%--------------------------------------------------------------------
%% Function: complete_handshake_header(socket(),
%%   info_hash(), peer_id()) -> ok
%% Description: Complete the handshake with the peer in the other end.
%%--------------------------------------------------------------------
complete_handshake_header(Socket, InfoHash, LocalPeerId) ->
    ok = gen_tcp:send(Socket, InfoHash),
    ok = gen_tcp:send(Socket, LocalPeerId),
    ok.

%%--------------------------------------------------------------------
%% Function: initiate_handshake(socket(), peer_id(), info_hash()) ->
%%                                         {ok, protocol_version()} |
%%                                              {error, Reason}
%% Description: Handshake with a peer where we have initiated with him.
%%  This call is used if we are the initiator of a torrent handshake as
%%  we then know the peer_id completely.
%%--------------------------------------------------------------------
initiate_handshake(Socket, LocalPeerId, InfoHash) ->
    % Since we are the initiator, send out this handshake
    Header = build_peer_protocol_header(),
    ok = gen_tcp:send(Socket, Header),
    complete_handshake_header(Socket, InfoHash, LocalPeerId),
    % Now, we wait for his handshake to arrive on the socket
    % Since we are the initiator, he is requested to fire off everything
    % to us.
    case receive_header(Socket) of
	{ok, ReservedBytes, IH, PI} ->
	    if
		IH /= InfoHash ->
		    {error, infohash_mismatch};
		true ->
		    {ok, ReservedBytes, PI}
	    end;
	{error, X} ->
	    {error, X}
    end.

%%====================================================================
%% Internal functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: build_peer_protocol_header() -> binary()
%% Description: Returns the Peer Protocol header.
%%--------------------------------------------------------------------
build_peer_protocol_header() ->
    PSSize = length(?PROTOCOL_STRING),
    <<PSSize:8, ?PROTOCOL_STRING, ?RESERVED_BYTES>>.

%%--------------------------------------------------------------------
%% Function: receive_header(socket()) -> {ok, proto_version(),
%%                                            info_hash(),
%%                                            remote_peer_id()} |
%%                                       {error, Reason}
%% Description: Recieve the full header from a peer. The function
%% returns either with an error or successfully with a
%% protocol_version string, the infohash the remote sent us and his
%% peer_id.
%% --------------------------------------------------------------------
receive_header(Socket) ->
    case gen_tcp:recv(Socket, ?HANDSHAKE_SIZE, ?DEFAULT_HANDSHAKE_TIMEOUT) of
	{ok, Packet} ->
	    <<PSL:8/integer, ?PROTOCOL_STRING, ReservedBytes:8/binary,
	     IH:20/binary, PI:20/binary>> = Packet,
	    if
		PSL /= length(?PROTOCOL_STRING) ->
		    {error, packet_size_mismatch};
		true ->
		    {ok, ReservedBytes, IH, PI}
	    end;
	{error, X} ->
	    {error, X}
    end.

%%--------------------------------------------------------------------
%% Function: construct_bitfield
%% Description: Construct a BitField for sending to the peer
%%--------------------------------------------------------------------
construct_bitfield(Size, PieceSet) ->
    PadBits = 8 - (Size rem 8),
    Bits = lists:append(
	     [etorrent_utils:list_tabulate(
		Size,
		fun(N) ->
			case sets:is_element(N, PieceSet) of
			    true -> 1;
			    false -> 0
			end
		end),
	      etorrent_utils:list_tabulate(
	       PadBits,
	       fun(_N) -> 0 end)]),
    0 = length(Bits) rem 8,
    list_to_binary(build_bytes(Bits)).

build_bytes(BitField) ->
    build_bytes(BitField, []).

build_bytes([], Acc) ->
    lists:reverse(Acc);
build_bytes(L, Acc) ->
    {Byte, Rest} = lists:split(8, L),
    build_bytes(Rest, [bytify(Byte) | Acc]).

bytify([B1, B2, B3, B4, B5, B6, B7, B8]) ->
    <<B1:1/integer, B2:1/integer, B3:1/integer, B4:1/integer,
      B5:1/integer, B6:1/integer, B7:1/integer, B8:1/integer>>.

destruct_bitfield(Size, BinaryLump) ->
    ByteList = binary_to_list(BinaryLump),
    Numbers = decode_bytes(0, ByteList, []),
    PieceSet = sets:from_list(lists:flatten(Numbers)),
    case max_element(PieceSet) < Size of
	true ->
	    {ok, PieceSet};
	false ->
	    {error, bitfield_had_wrong_padding}
    end.

max_element(Set) ->
    sets:fold(fun(E, Max) ->
		      case E > Max of
			  true ->
			      E;
			  false ->
			      Max
		      end
	      end, 0, Set).

decode_byte(B, Add) ->
    <<B1:1/integer, B2:1/integer, B3:1/integer, B4:1/integer,
      B5:1/integer, B6:1/integer, B7:1/integer, B8:1/integer>> = <<B>>,
    Select = lists:filter(fun({1, _}) -> true;
			     (_)      -> false
			  end, [{B1, 0}, {B2, 1}, {B3, 2}, {B4, 3},
				{B5, 4}, {B6, 5}, {B7, 6}, {B8, 7}]),
    Res = lists:map(fun({_, N}) ->
		      N + Add
	      end, Select),
    Res.

decode_bytes(_SoFar, [], Numbers) ->
    Numbers;
decode_bytes(SoFar, [Byte | Rest], Numbers) ->
    decode_bytes(SoFar + 8, Rest, [decode_byte(Byte, SoFar) | Numbers]).

