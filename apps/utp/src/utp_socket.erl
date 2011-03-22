-module(utp_socket).

-include("utp.hrl").

-export([
         mk/5,
         conn_id/1,
         set_conn_id/2
        ]).

-export([
         send_pkt/2
        ]).

-type ip_address() :: {byte(), byte(), byte(), byte()}.

-record(sock_info, {
	  %% Stuff pertaining to the socket:
	  addr        :: string() | ip_address(),
	  opts        :: proplists:proplist(), %% Options on the socket
	  packet_size :: integer(),
	  port        :: 0..16#FFFF,
	  socket      :: gen_udp:socket(),
          conn_id     :: 'not_set' | integer(),
          timestamp_difference :: integer()
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
                 conn_id = not_set,
                 timestamp_difference = 0
               }.

conn_id(#sock_info { conn_id = C }) ->
    C.

send_pkt(#sock_info { socket = Socket,
                      addr = Addr,
                      port = Port,
                      timestamp_difference = TSDiff}, Packet) ->
    %% @todo Handle timestamping here!!
    gen_udp:send(Socket, Addr, Port, utp_proto:encode(Packet, TSDiff)).

set_conn_id(Cid, SockInfo) ->
    SockInfo#sock_info { conn_id = Cid }.

