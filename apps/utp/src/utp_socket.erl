-module(utp_socket).

-include("log.hrl").
-include("utp.hrl").

-export([
         mk/5,
         set_conn_id/2,
         update_reply_micro/2,
         packet_size/1,

         order_packets/2,
         conn_id_recv/1,
         send_reset/6,
         hostname_port/1
        ]).

-export([
         send_pkt/3, send_pkt/4
        ]).

-type ip_address() :: inet:ip4_address().
-type port_number() :: 0..16#FFFF.

-record(sock_info, {
	  %% Stuff pertaining to the socket:
	  addr        :: string() | ip_address(),
	  opts        :: [{atom(), term()}], %% Options on the socket
	  packet_size :: integer(),
	  port        :: port_number(),
	  socket      :: inet:socket(),
          conn_id_send :: 'not_set' | integer(),
          reply_micro :: integer()
	 }).
-opaque t() :: #sock_info{}.
-export_type([t/0]).

%% ----------------------------------------------------------------------

mk(Addr, Opts, PacketSize, Port, Socket) ->
    #sock_info { addr = Addr,
                 opts = Opts,
                 packet_size = PacketSize,
                 port = Port,
                 socket = Socket,
                 conn_id_send = not_set,
                 reply_micro = 0
               }.

update_reply_micro(#sock_info {} = SockInfo, RU) ->
    SockInfo#sock_info { reply_micro = RU }.

hostname_port(#sock_info { addr = Addr, port = Port }) ->
    {Addr, Port}.

conn_id_recv(#sock_info { conn_id_send = ConnId }) ->
    ConnId - 1. % This is the receiver conn_id we use at the SYN point.

send_pkt(AdvWin, #sock_info { conn_id_send = ConnId } = SockInfo, Packet) ->
    send_pkt(AdvWin, SockInfo, Packet, ConnId).

send_pkt(AdvWin, #sock_info { socket = Socket,
                              addr = Addr,
                              port = Port,
                              reply_micro = TSDiff}, Packet, ConnId) ->
    Pkt = Packet#packet { conn_id = ConnId,
                          win_sz = AdvWin },
    ?DEBUG([node(), outgoing_pkt, utp_proto:format_pkt(Pkt)]),
    send(Socket, Addr, Port, Pkt, TSDiff).


send_reset(Socket, Addr, Port, ConnIDSend, AckNo, SeqNo) ->
    Packet =
        #packet { ty = st_reset,
                  ack_no = AckNo,
                  seq_no = SeqNo,
                  win_sz = 0,
                  extension = [],
                  conn_id = ConnIDSend },
    TSDiff = 0,
    send(Socket, Addr, Port, Packet, TSDiff).

send(Socket, Addr, Port, Packet, TSDiff) ->
    utp_proto:validate(Packet),
    send_aux(1, Socket, Addr, Port, utp_proto:encode(Packet, TSDiff)).

send_aux(0, Socket, Addr, Port, Payload) ->
    gen_udp:send(Socket, Addr, Port, Payload);
send_aux(N, Socket, Addr, Port, Payload) ->
    case gen_udp:send(Socket, Addr, Port, Payload) of
        ok ->
            {ok, utp_proto:current_time_us()};
        {error, enobufs} ->
            %% Special case this
            timer:sleep(150), % Wait a bit for the queue to clear
            send_aux(N-1, Socket, Addr, Port, Payload);
        {error, Reason} ->
            {error, Reason}
    end.
           

set_conn_id(Cid, SockInfo) ->
    SockInfo#sock_info { conn_id_send = Cid }.

order_packets(#packet { seq_no = S1 } = P1, #packet { seq_no = S2 } = P2) ->
    case S1 < S2 of
        true ->
            [P1, P2];
        false ->
            [P2, P1]
    end.

packet_size(_Socket) ->
    %% @todo FIX get_packet_size/1 to actually work!
    1000.
