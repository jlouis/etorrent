%% Various types spanning multiple modules.

-type operation() :: {integer(), integer(), integer()}.
-type bitfield() :: binary().
-type ip() :: {integer(), integer(), integer(), integer()}.
-type capabilities() :: extended_messaging.
% The bcode() type:
-type bstring() :: {'string', string()}.
-type binteger() :: {'integer', integer()}.
-type bcode() :: bstring()
               | binteger()
               | {'list', [bcode()]}
               | {'dict', [{bstring(), bcode()}]}.
-type bdict() :: {'dict', [{bstring(), bcode()}]}.

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
-type trackerinfo() :: {nodeid(), ipaddr(), portnum(),
                        token(), list(peerinfo())}.
-type dht_qtype() :: 'ping' | 'find_node'
                   | 'get_peers' | 'announce'.
