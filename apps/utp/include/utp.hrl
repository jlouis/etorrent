-type packet_type() :: st_data | st_fin | st_state | st_reset | st_syn.

-type extension() :: {sack, binary()} | {ext_bits, binary()}.
-type timestamp() :: integer().

-record(packet, { ty             :: packet_type(),
		  conn_id        :: integer(),
		  win_sz = 0     :: integer(),
		  seq_no         :: integer(),
		  ack_no         :: integer(),
		  extension = [] :: [extension()],
		  payload = <<>> :: binary()
		}).

-type packet() :: #packet{}.

-define(SEQ_NO_MASK, 16#FFFF).
-define(ACK_NO_MASK, 16#FFFF).
-define(REORDER_BUFFER_SIZE, 32).
-define(REORDER_BUFFER_MAX_SIZE, 511).
-define(OUTGOING_BUFFER_MAX_SIZE, 511).




