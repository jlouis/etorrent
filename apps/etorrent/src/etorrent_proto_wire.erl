%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Library module for handling the wire protocol
%% <p>This module implements a library of functions necessary to
%% handle the wire-protocol of etorrent. In this module there are
%% functions for encoding and decoding, etc</p>
%% @end
-module(etorrent_proto_wire).

-include("etorrent_version.hrl").

-export([incoming_packet/2,
	 send_msg/3,
	 decode_bitfield/2,
	 encode_bitfield/2,
	 decode_msg/1,
	 remaining_bytes/1,
	 complete_handshake/3,
	 receive_handshake/1,
	 extended_msg_contents/0,
	 initiate_handshake/3]).

-define(DEFAULT_HANDSHAKE_TIMEOUT, 120000).
-define(HANDSHAKE_SIZE, 68).
-define(PROTOCOL_STRING, "BitTorrent protocol").

%% Extensions
-define(EXT_BASIS, 0). % The protocol basis
-define(EXT_FAST,  4). % The Fast Extension
-define(EXT_EXTMSG, 1 bsl 20). % The extended message extension

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

%% FAST EXTENSION Packet types
-define(SUGGEST, 13:8).
-define(HAVE_ALL, 14:8).
-define(HAVE_NONE, 15:8).
-define(REJECT_REQUEST, 16:8).
-define(ALLOWED_FAST, 17:8).

%% Extended messaging
-define(EXTENDED, 20:8).

%% =======================================================================

% The type of packets:
-type packet() :: keep_alive
                | choke
                | unchoke
                | interested
                | not_interested
                | {have, integer()}
                | {bitfield, binary()}
                | {request, integer(), integer(), integer()}
                | {piece, integer(), integer(), binary()}
                | {cancel, integer(), integer(), integer()}
                | {port, integer()}
                | {suggest, integer()}
                | have_all
                | have_none
                | {reject_request, integer(), integer(), integer()}
                | {allowed_fast, [integer()]}
		| {extended, integer(), binary()}.

-type cont_state() :: {partial, binary() | {integer(), [binary()]}}.
-type continuation() :: cont_state() | none.
-export_type([continuation/0]).

%% @doc Decode an incoming (partial) packet
%% <p>The incoming packet function will attempt to decode an incoming packet. It
%% returns either the decoded packet, or it returns a partial continuation to
%% continue packet reading.</p>
%% <p>The function is used when a Socket is in "slow" mode and will
%% get less than a full packet in. We can then use this function and
%% its continuation-construction to eat up partial packets, until we
%% have the full one and can decode it.</p>
%% @end
-spec incoming_packet(none | cont_state(), binary()) ->
    ok | {ok, binary(), binary()} | cont_state().
incoming_packet(none, <<>>) -> ok;

incoming_packet(none, <<0:32/big-integer, Rest/binary>>) ->
    {ok, <<>>, Rest};

incoming_packet(none, <<Left:32/big-integer, Rest/binary>>) ->
    incoming_packet({partial, {Left, []}}, Rest);

incoming_packet({partial, Data}, <<More/binary>>) when is_binary(Data) ->
    incoming_packet(none, <<Data/binary, More/binary>>);

incoming_packet(none, Packet) when byte_size(Packet) < 4 ->
    {partial, Packet};

incoming_packet({partial, {Left, IOL}}, Packet)
        when byte_size(Packet) >= Left, is_integer(Left) ->
    <<Data:Left/binary, Rest/binary>> = Packet,
    Left = byte_size(Data),
    P = iolist_to_binary(lists:reverse([Data | IOL])),
    {ok, P, Rest};

incoming_packet({partial, {Left, IOL}}, Packet)
        when byte_size(Packet) < Left, is_integer(Left) ->
    {partial, {Left - byte_size(Packet), [Packet | IOL]}}.

%% @doc Send a message on a Socket.
%% <p>Returns a pair {R, Sz}, where R is the result of the send and Sz is the
%% size of the sent datagram.</p>
%% <p>The Mode supplied is either 'fast' or 'slow' depending on the
%% mode of the Socket in question.</p>
%% @end
-spec send_msg(port(), packet(), slow | fast) -> {ok | {error, term()},
                                                  integer()}.
send_msg(Socket, Msg, Mode) ->
    Datagram = encode_msg(Msg),
    Sz = byte_size(Datagram),
    case Mode of
        slow ->
            {gen_tcp:send(Socket, <<Sz:32/big, Datagram/binary>>), Sz};
        fast ->
            {gen_tcp:send(Socket, Datagram), Sz}
    end.

%% @doc Decode a binary bitfield into a pieceset
%% @end
-spec decode_bitfield(integer(), binary()) ->
    {ok, etorrent_pieceset:pieceset()}.
decode_bitfield(Size, Bin) ->
    PieceSet = etorrent_pieceset:from_binary(Bin, Size),
    {ok, PieceSet}.

% @doc Encode a pieceset into a binary bitfield
% <p>The Size entry is the full size of the bitfield, so the function knows
% how much and when to pad
% </p>
% @end
-spec encode_bitfield(integer(), etorrent_pieceset:pieceset()) -> binary().
encode_bitfield(_Size, Pieceset) ->
    etorrent_pieceset:to_binary(Pieceset).

%% @doc Decode a message from the wire
%% <p>This function take a binary input, assumed to be a wire protocol
%% packet. It then decodes this packet into an internally used
%% Erlang-term which is much easier to process.</p>
%% @end
-spec decode_msg(binary()) -> packet().
decode_msg(Message) ->
   case Message of
       <<>> -> keep_alive;
       <<?CHOKE>> -> choke;
       <<?UNCHOKE>> -> unchoke;
       <<?INTERESTED>> -> interested;
       <<?NOT_INTERESTED>> -> not_interested;
       <<?HAVE, PieceNum:32/big>> -> {have, PieceNum};
       <<?BITFIELD, BitField/binary>> -> {bitfield, BitField};
       <<?REQUEST, Index:32/big, Begin:32/big, Len:32/big>> ->
	   {request, Index, Begin, Len};
       <<?PIECE, Index:32/big, Begin:32/big, Data/binary>> ->
	   {piece, Index, Begin, Data};
       <<?CANCEL, Index:32/big, Begin:32/big, Len:32/big>> ->
	   {cancel, Index, Begin, Len};
       <<?PORT, Port:16/big>> -> {port, Port};
       %% FAST EXTENSION MESSAGES
       <<?SUGGEST, Index:32/big>> -> {suggest, Index};
       <<?HAVE_ALL>> -> have_all;
       <<?HAVE_NONE>> -> have_none;
       <<?REJECT_REQUEST, Index:32, Offset:32, Len:32>> ->
           {reject_request, Index, Offset, Len};
       <<?ALLOWED_FAST, FastSet/binary>> ->
           {allowed_fast, decode_allowed_fast(FastSet)};
       %% EXTENDED MESSAGING
       <<?EXTENDED, Type:8, Contents/binary>> ->
	   {extended, Type, Contents}
   end.

%% @doc Tell how many bytes there are left on a continuation
%% <p>Occasionally, we will need to know how many bytes we are missing on a
%% continuation, before we have to full packet. This function reports this.</p>
%% @end
-spec remaining_bytes(none | cont_state()) -> {val, integer()}.
remaining_bytes(none) -> {val, 0};
remaining_bytes({partial, _D}) when is_binary(_D) -> {val, 0};
remaining_bytes({partial, {Left, _}}) when is_integer(Left) -> {val, Left}.

%% @doc Complete a partially initiated handshake.
%% <p>This function is used for incoming peer connections. They start off by
%% transmitting all their information, we check it against our current database
%% of what we accept. If we accept the message, then this function is called to
%% complete the handshake by reflecting back the correct handshake to the
%% peer.</p>
%% @end
-spec complete_handshake(port(), binary(), binary()) ->
    ok | {error, term()}.
complete_handshake(Socket, InfoHash, LocalPeerId) ->
    try
        ok = gen_tcp:send(Socket, InfoHash),
        ok = gen_tcp:send(Socket, LocalPeerId),
        ok
    catch
        error:_ -> {error, stop}
    end.

%% @doc Receive and incoming handshake
%% <p>If the handshake is in the incoming direction, the method is to fling off
%% the protocol header, so the peer knows we are talking bittorrent. Then it
%% waits for the header to arrive. If the header is good, the connection can be
%% completed by a call to complete_handshake/3.</p>
%% @end
-spec receive_handshake(port()) ->
    {'error',term() | {'bad_header',binary()}}
    | {'ok',['extended_messaging' | 'fast_extension',...],<<_:160>>}
    | {'ok',['extended_messaging' | 'fast_extension',...],<<_:160>>,<<_:160>>}.
receive_handshake(Socket) ->
    Header = protocol_header(),
    case gen_tcp:send(Socket, Header) of
        ok ->
            receive_header(Socket, await);
        {error, X}  ->
            {error, X}
    end.

%% @doc Initiate a handshake in the outgoing direction
%% <p>If we are initiating a connection, then it is simple. We just fling off
%% everything to the peer and await the peer to get back to us. When he
%% eventually gets back, we can check his InfoHash against ours.</p>
%% @end
-type peerid() :: <<_:160>>.
-type infohash() :: <<_:160>>.
-spec initiate_handshake(port(), peerid(), infohash()) ->
     {'error',atom() | {'bad_header',binary()}}
     | {'ok',['extended_messaging' | 'fast_extension',...],<<_:160>>}.
initiate_handshake(Socket, LocalPeerId, InfoHash) ->
    % Since we are the initiator, send out this handshake
    Header = protocol_header(),
    try
        ok = gen_tcp:send(Socket, Header),
        ok = gen_tcp:send(Socket, InfoHash),
        ok = gen_tcp:send(Socket, LocalPeerId),
        receive_header(Socket, InfoHash)
    catch
        error:_ -> {error, stop}
    end.

%% @doc Return the default contents of the Extended Messaging Protocol (BEP-10)
%% <p>This function builds up the extended messaging contents default
%% bcoded term to send to a peer, when the peer has been negotiated to
%% support the extended messaging protocol (BEP-10).</p>
%% <p>Note that the contents are returned as a binary() type.</p>
%% @end
-spec extended_msg_contents() -> binary().
extended_msg_contents() ->
    Port = etorrent_config:listen_port(),
    extended_msg_contents(Port, ?AGENT_TRACKER_STRING, 250).

%% =======================================================================

%% Encode a message for the wire
encode_msg(Message) ->
   case Message of
       keep_alive -> <<>>;
       choke -> <<?CHOKE>>;
       unchoke -> <<?UNCHOKE>>;
       interested -> <<?INTERESTED>>;
       not_interested -> <<?NOT_INTERESTED>>;
       {have, PieceNum} -> <<?HAVE, PieceNum:32/big>>;
       {bitfield, BitField} -> <<?BITFIELD, BitField/binary>>;
       {request, Index, Begin, Len} -> <<?REQUEST, Index:32/big, Begin:32/big, Len:32/big>>;
       {piece, Index, Begin, Data} -> <<?PIECE, Index:32/big, Begin:32/big, Data/binary>>;
       {cancel, Index, Begin, Len} -> <<?CANCEL, Index:32/big, Begin:32/big, Len:32/big>>;
       {port, PortNum} -> <<?PORT, PortNum:16/big>>;
       %% FAST EXTENSION
       {suggest, Index} -> <<?SUGGEST, Index:32>>;
       have_all -> <<?HAVE_ALL>>;
       have_none -> <<?HAVE_NONE>>;
       {reject_request, Index, Offset, Len} -> <<?REJECT_REQUEST, Index, Offset, Len>>;
       {allowed_fast, FastSet} ->
           BinFastSet = encode_fastset(FastSet),
           <<?ALLOWED_FAST, BinFastSet/binary>>;
       %% EXTENDED MESSAGING
       {extended, Type, Contents} ->
	   <<?EXTENDED, Type:8, Contents/binary>>
   end.






protocol_header() ->
    PSSize = length(?PROTOCOL_STRING),
    ReservedBytes = encode_proto_caps(),
    <<PSSize:8, ?PROTOCOL_STRING, ReservedBytes/binary>>.


%%--------------------------------------------------------------------
%% Function: receive_header(socket()) -> {ok, proto_version(),
%%                                            remote_peer_id()} |
%%                                       {ok, proto_version(),
%%                                            info_hash(),
%%                                            remote_peer_id()} |
%%                                       {error, Reason}
%% Description: Receive the full header from a peer. The function
%% returns either with an error or successfully with a
%% protocol_version string, the infohash the remote sent us and his
%% peer_id.
%% --------------------------------------------------------------------
receive_header(Socket, InfoHash) ->
    %% Last thing we do on the socket, catch an error here.
    case gen_tcp:recv(Socket, ?HANDSHAKE_SIZE, ?DEFAULT_HANDSHAKE_TIMEOUT) of
        %% Fail if the header length is wrong
        {ok, <<PSL:8/integer, ?PROTOCOL_STRING, _:8/binary,
               _IH:20/binary, _PI:20/binary>>}
          when PSL /= length(?PROTOCOL_STRING) ->
            {error, packet_size_mismatch};
        %% If the infohash is await, return the infohash along.
        {ok, <<_PSL:8/integer, ?PROTOCOL_STRING, ReservedBytes:64/big,
               IH:20/binary, PI:20/binary>>}
          when InfoHash =:= await ->
            {ok, decode_proto_caps(ReservedBytes), IH, PI};
        %% Infohash mismatches. Error it.
        {ok, <<_PSL:8/integer, ?PROTOCOL_STRING, _ReservedBytes:64/big,
               IH:20/binary, _PI:20/binary>>}
          when IH /= InfoHash ->
            {error, infohash_mismatch};
        %% Everything ok
        {ok, <<_PSL:8/integer, ?PROTOCOL_STRING, ReservedBytes:64/big,
               _IH:20/binary, PI:20/binary>>} ->
            {ok, decode_proto_caps(ReservedBytes), PI};
        %% This is not even a header!
        {ok, X} when is_binary(X) ->
            {error, {bad_header, X}};
        %% Propagate errors upwards, most importantly, {error, closed}
        {error, Reason} ->
            {error, Reason}
    end.


%% PROTOCOL CAPS

encode_proto_caps() ->
    ProtoSpec = lists:sum([%?EXT_FAST,
			   ?EXT_EXTMSG,
                           ?EXT_BASIS]),
    <<ProtoSpec:64/big>>.

decode_proto_caps(N) ->
    Capabilities = [{?EXT_FAST,  fast_extension},
		    {?EXT_EXTMSG, extended_messaging}],
    Decoded = lists:foldl(
      fun
          ({M, Cap}, Acc) when (M band N) > 0 -> [Cap | Acc];
          (_Capability, Acc) -> Acc
      end,
      Capabilities,
      []),
    [Cap || {_, Cap} <- Decoded].


%% FASTSET COMPUTATION

decode_allowed_fast(<<>>) -> [];
decode_allowed_fast(<<Index:32, Rest/binary>>) ->
    [Index | decode_allowed_fast(Rest)].

encode_fastset([]) -> <<>>;
encode_fastset([Idx | Rest]) ->
    R = encode_fastset(Rest),
    <<R/binary, Idx:32>>.

-spec extended_msg_contents(port(), string(), integer()) -> binary().
extended_msg_contents(Port, ClientVersion, ReqQ) ->
    iolist_to_binary(
      etorrent_bcoding:encode(
	[{<<"p">>, Port},
	 {<<"v">>, list_to_binary(ClientVersion)},
	 {<<"reqq">>, ReqQ},
	 {<<"m">>, empty_dict}])).


