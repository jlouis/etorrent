-module(utp_proto).

-include("utp.hrl").

-ifdef(TEST).
-include_lib("eqc/include/eqc.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([mk_connection_id/0,
         current_time_us/0,
         current_time_ms/0,
	 payload_size/1,
	 encode/2,
	 decode/1,
         
         validate/1,
         format_pkt/1
        ]).

-export([mk_syn/0]).

-export([mk_ack/2]).
%% Default extensions to use when SYN/SYNACK'ing
-define(SYN_EXTS, [{ext_bits, <<0:64/integer>>}]).

-type conn_id() :: 0..16#FFFF.
-export_type([packet/0,
              conn_id/0]).

-define(EXT_SACK, 1).
-define(EXT_BITS, 2).

-define(ST_DATA,  0).
-define(ST_FIN,   1).
-define(ST_STATE, 2).
-define(ST_RESET, 3).
-define(ST_SYN,   4).

format_pkt(#packet { ty = Ty, conn_id = ConnID, win_sz = WinSz,
                     seq_no = SeqNo,
                     ack_no = AckNo,
                     extension = Exts,
                     payload = Payload }) ->
    [{ty, Ty}, {conn_id, ConnID}, {win_sz, WinSz},
     {seq_no, SeqNo}, {ack_no, AckNo}, {extension, Exts},
     {payload,
      byte_size(Payload)}].

-spec mk_connection_id() -> conn_id().
mk_connection_id() ->
    <<N:16/integer>> = crypto:rand_bytes(2),
    N.

payload_size(#packet { payload = PL }) ->
    byte_size(PL).

-spec current_time_us() -> integer().
current_time_us() ->
    {M, S, Micro} = os:timestamp(),
    S1 = M*1000000 + S,
    Micro + S1*1000000.

-spec current_time_ms() -> integer().
current_time_ms() ->
    {M, S, Micro} = os:timestamp(),
    (Micro div 1000) + S*1000 + M*1000000*1000.

-spec encode(packet(), timestamp()) -> binary().
encode(#packet { ty = Type,
		 conn_id = ConnID,
		 win_sz = WSize,
		 seq_no = SeqNo,
		 ack_no = AckNo,
		 extension = ExtList,
		 payload = Payload}, TSDiff) ->
    {Extension, ExtBin} = encode_extensions(ExtList),
    EncTy = encode_type(Type),
    TS    = current_time_us(),
    <<1:4/integer, EncTy:4/integer, Extension:8/integer, ConnID:16/integer,
      TS:32/integer,
      TSDiff:32/integer,
      WSize:32/integer,
      SeqNo:16/integer, AckNo:16/integer,
      ExtBin/binary,
      Payload/binary>>.

-spec decode(binary()) -> {packet(), timestamp(), timestamp(), timestamp()}.
decode(Packet) ->
    TS = current_time_us(),

    %% Decode packet
    <<1:4/integer, Type:4/integer, Extension:8/integer, ConnectionId:16/integer,
      TimeStamp:32/integer,
      TimeStampdiff:32/integer,
      WindowSize:32/integer,
      SeqNo:16/integer,
      AckNo:16/integer,
      ExtPayload/binary>> = Packet,
    {Extensions, Payload} = decode_extensions(Extension, ExtPayload, []),

    %% Validate packet contents
    Ty = decode_type(Type),
    ok = validate_packet_type(Ty, Payload),

    {#packet { ty = Ty,
               conn_id = ConnectionId,
               win_sz = WindowSize,
               seq_no = SeqNo,
               ack_no = AckNo,
               extension = Extensions,
               payload = Payload},
     TimeStamp,
     TimeStampdiff,
     TS}.

validate(#packet { seq_no = SeqNo,
                   ack_no = AckNo } = Pkt) ->
    case (0 =< SeqNo andalso SeqNo =< 65535)
         andalso
         (0 =< AckNo andalso AckNo =< 65535) of
        true ->
            true;
        false ->
            format_pkt(Pkt),
            false
    end.


validate_packet_type(Ty, Payload) ->
    case Ty of
        st_state when Payload == <<>> ->
            ok;
        st_data when Payload =/= <<>> ->
            ok;
        st_fin ->
            ok;
        st_syn ->
            ok;
        st_reset ->
            ok
    end.

decode_extensions(0, Payload, Exts) ->
    {lists:reverse(Exts), Payload};
decode_extensions(?EXT_SACK, <<Next:8/integer,
			       Len:8/integer, R/binary>>, Acc) ->
    <<Bits:Len/binary, Rest/binary>> = R,
    decode_extensions(Next, Rest, [{sack, Bits} | Acc]);
decode_extensions(?EXT_BITS, <<Next:8/integer,
			       Len:8/integer, R/binary>>, Acc) ->
    <<ExtBits:Len/binary, Rest/binary>> = R,
    decode_extensions(Next, Rest, [{ext_bits, ExtBits} | Acc]).

encode_extensions([]) -> {0, <<>>};
encode_extensions([{sack, Bits} | R]) ->
    {Next, Bin} = encode_extensions(R),
    Sz = byte_size(Bits),
    {?EXT_SACK, <<Next:8/integer, Sz:8/integer, Bits/binary, Bin/binary>>};
encode_extensions([{ext_bits, Bits} | R]) ->
    {Next, Bin} = encode_extensions(R),
    Sz = byte_size(Bits),
    {?EXT_BITS, <<Next:8/integer, Sz:8/integer, Bits/binary, Bin/binary>>}.

decode_type(?ST_DATA) -> st_data;
decode_type(?ST_FIN) -> st_fin;
decode_type(?ST_STATE) -> st_state;
decode_type(?ST_RESET) -> st_reset;
decode_type(?ST_SYN) -> st_syn.

encode_type(st_data) -> ?ST_DATA;
encode_type(st_fin) -> ?ST_FIN;
encode_type(st_state) -> ?ST_STATE;
encode_type(st_reset) -> ?ST_RESET;
encode_type(st_syn) -> ?ST_SYN.

-ifdef(EUNIT).
-ifdef(EQC).

g_type() ->
    oneof([st_data, st_fin, st_state, st_reset, st_syn]).

g_timestamp() ->
    choose(0, 256*256*256*256-1).

g_uint32() ->
    choose(0, 256*256*256*256-1).

g_uint16() ->
    choose(0, 256*256-1).

g_extension_one() ->
    ?LET({What, Bin}, {oneof([sack, ext_bits]), binary()},
	 {What, Bin}).

g_extension() ->
    list(g_extension_one()).

g_packet() ->
    ?LET({Ty, ConnID, WindowSize, SeqNo, AckNo,
	  Extension, Payload},
	 {g_type(), g_uint16(), g_uint32(), g_uint16(), g_uint16(),
	  g_extension(), binary()},
                 #packet { ty = Ty, conn_id = ConnID, win_sz = WindowSize,
                           seq_no = SeqNo, ack_no = AckNo, extension = Extension,
                           payload = case Ty of st_state -> <<>>; _ -> Payload end }).

prop_ext_dec_inv() ->
    ?FORALL(E, g_extension(),
	    begin
		{Next, B} = encode_extensions(E),
		{E, <<>>} =:= decode_extensions(Next, B, [])
	    end).

prop_decode_inv() ->
    ?FORALL({P, T1}, {g_packet(), g_timestamp()},
	    begin
                Encoded = encode(P, T1),
                {Packet, _, _, _} = decode(Encoded),
                P =:= Packet

                %%{P1, _, T11, _} = decode(encode(P, T1)),
                %%{P1, T11} =:= {P, T1}
	    end).

inverse_extension_test() ->
    ?assert(eqc:quickcheck(prop_ext_dec_inv())).

inverse_decode_test() ->
    ?assert(eqc:quickcheck(prop_decode_inv())).

-endif.
-endif.



mk_syn() ->
     #packet { ty = st_syn,
               seq_no = 1,
               ack_no = 0,
               extension = ?SYN_EXTS
             }. % Rest are defaults

mk_ack(SeqNo, AckNo) ->
    #packet {ty = st_state,
	     seq_no = SeqNo,
	     ack_no = AckNo,
	     extension = ?SYN_EXTS
           }.