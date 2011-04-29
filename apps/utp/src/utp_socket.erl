-module(utp_socket).

-include("utp.hrl").

-export([
         mk/5,
         set_conn_id/2
        ]).

-export([
         send_pkt/3, send_pkt/4,
         format_pkt/1
        ]).

-type ip_address() :: {byte(), byte(), byte(), byte()}.

-record(sock_info, {
	  %% Stuff pertaining to the socket:
	  addr        :: string() | ip_address(),
	  opts        :: proplists:proplist(), %% Options on the socket
	  packet_size :: integer(),
	  port        :: 0..16#FFFF,
	  socket      :: gen_udp:socket(),
          conn_id_send :: 'not_set' | integer(),
          timestamp_difference :: integer()
	 }).
-opaque t() :: #sock_info{}.
-export_type([t/0]).

%% ----------------------------------------------------------------------

format_pkt(#packet { ty = Ty, conn_id = ConnID, win_sz = WinSz,
                     seq_no = SeqNo,
                     ack_no = AckNo,
                     extension = Exts,
                     payload = Payload }) ->
    [{ty, Ty}, {conn_id, ConnID}, {win_sz, WinSz},
     {seq_no, SeqNo}, {ack_no, AckNo}, {extension, Exts},
     {payload,
      byte_size(Payload)}].

mk(Addr, Opts, PacketSize, Port, Socket) ->
    #sock_info { addr = Addr,
                 opts = Opts,
                 packet_size = PacketSize,
                 port = Port,
                 socket = Socket,
                 conn_id_send = not_set,
                 timestamp_difference = 0
               }.

send_pkt(AdvWin, #sock_info { conn_id_send = ConnId } = SockInfo, Packet) ->
    send_pkt(AdvWin, SockInfo, Packet, ConnId).

send_pkt(AdvWin, #sock_info { socket = Socket,
                              addr = Addr,
                              port = Port,
                              timestamp_difference = TSDiff}, Packet, ConnId) ->
    %% @todo Handle timestamping here!!
    Pkt = Packet#packet { conn_id = ConnId,
                          win_sz = AdvWin },
    error_logger:info_report([pkt, format_pkt(Pkt)]),
    gen_udp:send(Socket, Addr, Port,
                 utp_proto:encode(
                   Pkt,
                   TSDiff)).

set_conn_id(Cid, SockInfo) ->
    SockInfo#sock_info { conn_id_send = Cid }.





