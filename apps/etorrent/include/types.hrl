%% Various types spanning multiple modules.
-type tier() :: [string()].
-type bitfield() :: binary().
-type capabilities() :: extended_messaging.
% The bcode() type:
-type bstring() :: {'string', string()}.
-type binteger() :: {'integer', integer()}.
-type bcode() :: integer()
	       | binary()
	       | [bcode()]
	       | [{string(), bcode()}].
-type bdict() :: [{string(), bcode()}].
-type torrent_id() :: integer().
-type file_path() :: string().

% Type returned by the From tag in gen_*:handle_call
-type from_tag() :: {pid(), term()}.

% There are three types of blocks, define types for
% all three to make it easier to distinguish which type
% a function works with.
-type piece_index() :: pos_integer().
-type piece_bin() :: binary().
-type chunk_offset() :: pos_integer().
-type chunk_len() :: pos_integer().
-type chunk_bin() :: binary().
-type block_len() :: pos_integer().
-type block_offset() :: pos_integer().
-type block_bin() :: binary().

% Event you can send to the tracker.
-type tracker_event() :: completed | started | stopped.

% Types used by the DHT subsystem
-type ipaddr() :: {byte(), byte(), byte(), byte()}.
-type portnum() :: 1..16#FFFF.
-type infohash() :: pos_integer().
-type nodeid() :: pos_integer().
-type nodeinfo() :: {nodeid(), ipaddr(), portnum()}.
-type peerinfo() :: {ipaddr(), portnum()}.
-type token() :: binary().
-type transaction() :: binary().
-type trackerinfo() :: {nodeid(), ipaddr(), portnum(), token()}.
-type dht_qtype() :: 'ping' | 'find_node'
                   | 'get_peers' | 'announce'.





