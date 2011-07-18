-module(utp_socket).

-include("log.hrl").
-include("utp.hrl").

-export([
         mk/4,
         set_conn_id/2,
         packet_size/1,
         send_buf_sz/1,

         send_pkt/3,
         order_packets/2,
         conn_id_recv/1,
         conn_id/1,
         send_reset/6,
         hostname_port/1
        ]).

-type ip_address() :: inet:ip4_address().
-type port_number() :: 0..16#FFFF.
-define(OUTGOING_BUFFER_MAX_SIZE, 511).
-define(PACKET_SIZE, 350).
-define(OPT_SEND_BUF, ?OUTGOING_BUFFER_MAX_SIZE * ?PACKET_SIZE).

-record(sock_info, {
	  %% Stuff pertaining to the socket:
	  addr        :: string() | ip_address(),
	  opts        :: [{atom(), term()}], %% Options on the socket
	  port        :: port_number(),
	  socket      :: inet:socket(),
          conn_id_send :: 'not_set' | integer(),

          %% Size of the outgoing buffer on the socket
          opt_snd_buf_sz  = ?OPT_SEND_BUF :: integer()

	 }).
-opaque t() :: #sock_info{}.
-export_type([t/0]).

%% ----------------------------------------------------------------------

mk(Addr, Opts, Port, Socket) ->
    #sock_info { addr = Addr,
                 opts = Opts,
                 port = Port,
                 socket = Socket,
                 conn_id_send = not_set
               }.

send_buf_sz(#sock_info { opt_snd_buf_sz = SBZ }) ->
    SBZ.

hostname_port(#sock_info { addr = Addr, port = Port }) ->
    {Addr, Port}.

conn_id(#sock_info { conn_id_send = ConnId }) ->
    ConnId.

conn_id_recv(#sock_info { conn_id_send = ConnId }) ->
    ConnId - 1. % This is the receiver conn_id we use at the SYN point.

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

send_pkt(#sock_info {
            addr = Addr,
            port = Port,
            socket = Socket },
         Pkt, TSDiff) ->
    send(Socket, Addr, Port, Pkt, TSDiff).

send(Socket, Addr, Port, Packet, TSDiff) ->
    utp_proto:validate(Packet),
    utp:report_event(50, us, peer, utp_proto:succinct_format_packet(Packet), [{addr_port, Addr, Port},
                                            {packet, Packet}]),
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


     








