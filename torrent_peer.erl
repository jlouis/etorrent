-module(torrent_peer).

-export([init/1, recv_handshake/3, send_handshake/3]).
-export([send_message/2]).

-define(PROTOCOL_STRING, "BitTorrent protocol").
-define(RESERVED_BYTES, <<0:64>>).

%% Packet types
-define(KEEP_ALIVE, 0:32/big).
-define(CHOKE, 1:32/big, 0:8).
-define(UNCHOKE, 1:32/big, 1:8).
-define(INTERESTED, 1:32/big, 2:8).
-define(NOT_INTERESTED, 1:32/big, 3:8).
-define(HAVE, 5:32/big, 4:8). %% PieceNum:32/big
-define(BITFIELD, 5:8). %% Binds
                        %% <<Len+1:32/big, ?BITFIELD, BitField:Len*8/binary>>
-define(REQUEST, 13:32/big, 6:8). %% Index:32/big, Begin:32/big, Len:32/big
-define(PIECE, 7:8). %% Binds
                     %% <<(9+Len):32/big, ?PIECE, Index:32/big, Begin:32/big,
                     %%   Data:Len*8/binary>>
-define(CANCEL, 13:32/big, 8:8). %% Index:32/big, Begin:32/big, Len:32/big
-define(PORT, 3:32/big, 9:8). %% Port:16/big

send_message(Socket, Message) ->
    Datagram = case Message of
	       keep_alive ->
		   <<?KEEP_ALIVE>>;
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
		   Size = size(BitField)+1,
		   <<Size:32/big, ?BITFIELD, BitField/binary>>;
	       {request, Index, Begin, Len} ->
		   <<?REQUEST, Index:32/big, Begin:32/big, Len:32/big>>;
	       {piece, Index, Begin, Data} ->
		   Size = size(Data)+9,
		   <<Size, ?PIECE, Index:32/big, Begin:32/big, Data/binary>>;
	       {cancel, Index, Begin, Len} ->
		   <<?CANCEL, Index:32/big, Begin:32/big, Len:32/big>>;
	       {port, PortNum} ->
		   <<?PORT, PortNum:16/big>>
	  end,
    gen_tcp:send(Socket, Datagram).

init(Socket) ->
    {ok, {Socket, choked, noninterested}}.

%% recv_loop({Socket, Choke, Interest}) ->
%%     case gen_tcp:recv(Socket, ...) of
%% 	{ok, Packet} ->
%% 	    NewState = dispatch_on_packet(Packet, {Socket, Choke, Interest}),
%% 	    torrent_peer_receive:recv_loop(NewState);
%% 	{error, closed} ->
%% 	    report_closed({Socket, Choke, Interest});
%% 	{error, Reason} ->
%% 	    report_closed({Socket, Choke, Interest}, Reason)
%%     end.

%% dispatch_on_packet(Packet, {Socket, Choke, Interest}) ->

build_handshake(PeerId, InfoHash) ->
    PStringLength = lists:length(?PROTOCOL_STRING),
    <<PStringLength:8, ?PROTOCOL_STRING, ?RESERVED_BYTES, InfoHash, PeerId>>.

send_handshake(Socket, PeerId, InfoHash) ->
    ok = gen_tcp:send(Socket, build_handshake(PeerId, InfoHash)).

recv_handshake(Socket, PeerId, InfoHash) ->
    Size = size(build_handshake(PeerId, InfoHash)),
    {ok, Packet} = gen_tcp:recv(Socket, Size),
    <<PSL:8,
     ?PROTOCOL_STRING,
     ReservedBytes:64/binary, IH:160/binary, PI:160/binary>> = Packet,
    if
	PSL /= Size ->
	    {error, "Size mismatch"};
	IH /= InfoHash ->
	    {error, "Infohash mismatch"};
	ReservedBytes /= ?RESERVED_BYTES ->
	    {error, "ReservedBytes error"};
	true ->
	    {ok, PI}
    end.

