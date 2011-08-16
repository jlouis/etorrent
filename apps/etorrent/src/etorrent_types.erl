-module(etorrent_types).

-export_type([
    bcode/0,
    tier/0,
    bitfield/0,
    capabilities/0,
    torrent_id/0,
    file_path/0,
    from_tag/0,
    piece_index/0,
    piece_bin/0,
    chunk_offset/0,
    chunk_len/0,
    chunk_bin/0,
    block_len/0,
    block_offset/0,
    block_bin/0,
    tracker_event/0,
    infohash/0,
    nodeinfo/0,
    peerinfo/0,
    transaction/0,
    trackerinfo/0,
    dht_qtype/0,
    token/0,
    portnum/0,
    upnp_device/0,
    upnp_service/0,
    upnp_notify/0]).

-type tier() :: [string()].
-type bitfield() :: binary().
-type capabilities() :: extended_messaging.

% The bcode() type:
-type bcode() ::
    integer()
	| binary()
	| [bcode(),...]
	| [{binary(), bcode()},...]
        | {}.

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
% Currently there are two flavors of info hash used in etorrent
% code. One is a 160-bit binary produced by crypto:sha/1. The other
% is an integer decoded from such binary, which is used exclusively
% by DHT. DHT subsystem also uses it as node id and computes nodes
% distance by 'xor' their ids. Xor can not be applied on binaries.
% Thus the distinction.
-type infohash() :: pos_integer().
-type nodeid() :: pos_integer().
-type nodeinfo() :: {nodeid(), ipaddr(), portnum()}.
-type peerinfo() :: {ipaddr(), portnum()}.
-type token() :: binary().
-type transaction() :: binary().
-type trackerinfo() :: {nodeid(), ipaddr(), portnum(), token()}.

-type dht_qtype() :: 'ping' | 'find_node' | 'get_peers' | 'announce'.

%% Types used by UPnP subsystem
-type upnp_device() :: proplists:proplist().
-type upnp_service() :: proplists:proplist().
-type upnp_notify() :: proplists:proplist().

