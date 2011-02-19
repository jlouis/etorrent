-module(etorrent_utp_proto).

-export([mk_connection_id/0,
	 encode/1,
	 decode/1]).

-define(EXT_SACK, 1).
-define(EXT_BITS, 2).

-define(ST_DATA,  0).
-define(ST_FIN,   1).
-define(ST_STATE, 2).
-define(ST_RESET, 3).
-define(ST_SYN,   4).

-spec mk_connection_id() -> 0..65535.
mk_connection_id() ->
    <<N:16/integer>> = crypto:rand_bytes(2),
    N.

encode({packet, Type, ConnID, TS, TSDiff, WSize, SeqNo, AckNo, ExtList, Payload}) ->
    {Extension, ExtBin} = encode_extensions(ExtList),
    EncTy = encode_type(Type),
    <<1:4/integer, EncTy:4/integer, Extension:8/integer, ConnID:16/integer,
      TS:32/integer,
      TSDiff:32/integer,
      WSize:32/integer,
      SeqNo:16/integer, AckNo:16/integer,
      ExtBin/binary,
      Payload/binary>>.

decode(Packet) ->
    case Packet of
	<<1:4/integer, Type:4/integer, Extension:8/integer, ConnectionId:16/integer,
	  TimeStamp:32/integer,
	  TimeStampdiff:32/integer,
	  WindowSize:32/integer,
	  SeqNo:16/integer, AckNo:16/integer,
	ExtPayload/binary>> ->
	    {Extensions, Payload} = decode_extensions(Extension, ExtPayload, []),
	    {packet,
	     decode_type(Type), ConnectionId,
	     TimeStamp,
	     TimeStampdiff,
	     WindowSize,
	     SeqNo, AckNo,
	     Extensions, Payload}
    end.

decode_extensions(0, Payload, Exts) ->
    {Exts, Payload};
decode_extensions(?EXT_SACK, <<Next:8/integer,
			       Len:8/integer, R/binary>>, Acc) ->
    <<Bits:Len/binary, Rest/binary>> = R,
    decode_extensions(Next, Rest, [{sack, Bits} | Acc]);
decode_extensions(?EXT_BITS, <<Next:8/integer,
			       Len:8/integer, R/binary>>, Acc) ->
    <<ExtBits:Len/binary, Rest/binary>> = R,
    decode_extensions(Next, Rest, [{ext_bits, ExtBits} | Acc]).

encode_extensions([{sack, Bits} | R]) ->
    {Next, Bin} = encode_extensions(R),
    Sz = byte_size(Bits),
    {?EXT_SACK, <<Next:8/integer, Sz:8/integer, Bin/binary>>};
encode_extensions([{ext_bits, Bits} | R]) ->
    {Next, Bin} = encode_extensions(R),
    Sz = byte_size(Bits),
    {?EXT_BITS, <<Next:8/integer, Sz:8/integer, Bin/binary>>}.

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











