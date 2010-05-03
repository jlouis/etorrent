-type(tracking_map_state() :: 'started' | 'stopped' | 'checking' | 'awaiting' | 'duplicate').

%% The tracking map tracks torrent id's to filenames, etc. It is the high-level view
-record(tracking_map, {id :: integer(), %% Unique identifier of torrent
                       filename :: string(),    %% The filename
                       supervisor_pid :: pid(), %% The Pid of who is supervising the torrent
                       info_hash :: binary() | 'unknown',
                       state :: tracking_map_state()}).

%% The path map tracks file system paths and maps them to integers.
-record(path_map, {id :: {non_neg_integer() | '_', non_neg_integer()},
                   path :: string() | '_'}). % (IDX) File system path minus work dir

-type(torrent_state() :: 'leeching' | 'seeding' | 'endgame' | 'unknown').

%% A single torrent is represented as the 'torrent' record
-record(torrent, {id :: non_neg_integer(), % Unique identifier of torrent, monotonically increasing
                                           % foreign keys to tracking_map.id
                  left :: non_neg_integer(), % How many bytes are there left before we have the
                                             % full torrent
                  total  :: non_neg_integer(), % How many bytes are there in total
                  uploaded :: non_neg_integer(), % How many bytes have we uploaded
                  downloaded :: non_neg_integer(), % How many bytes have we downloaded
                  pieces = unknown :: non_neg_integer() | 'unknown', % Number of pieces this torrent has
                  seeders = 0 :: non_neg_integer(), % How many people have a completed file?
                  leechers = 0 :: non_neg_integer(), % How many people are downloaded
                  state :: torrent_state()}). % What is our state: leecher | unknown | seeder | endgame

%% Counter for how many pieces is missing from this torrent
-record(torrent_c_pieces, {id :: non_neg_integer(), % Torrent id
                           missing :: non_neg_integer()}). % Number of missing pieces

-record(peer, {pid :: pid(), % We identify each peer with it's pid.
               ip,  % Ip of peer in question
               port :: non_neg_integer(), % Port of peer in question
               torrent_id :: non_neg_integer(), % (IDX) Torrent Id this peer belongs to
               state :: 'seeding' | 'leeching'}).

-type(diskstate_state() :: 'seeding' | {'bitfield', binary()}).
%% Piece state on disk for persistence
-record(piece_diskstate, {filename :: string(), % Name of torrent
                          state :: diskstate_state()}). % state | {bitfield, BF}

