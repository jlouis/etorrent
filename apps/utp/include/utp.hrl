-type packet_type() :: st_data | st_fin | st_state | st_reset | st_syn.

-type extension() :: {sack, binary()} | {ext_bits, binary()}.
-type timestamp() :: integer().

-record(packet, { ty :: packet_type(),
		  conn_id :: integer(),
		  win_sz :: integer(),
		  seq_no :: integer(),
		  ack_no :: integer(),
		  extension :: [extension()],
		  payload :: binary()
		}).

-type packet() :: #packet{}.

