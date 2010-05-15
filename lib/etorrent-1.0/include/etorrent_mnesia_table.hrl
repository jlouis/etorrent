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

%% Counter for how many pieces is missing from this torrent
-record(torrent_c_pieces, {id :: non_neg_integer(), % Torrent id
                           missing :: non_neg_integer()}). % Number of missing pieces

-record(peer, {pid :: pid(), % We identify each peer with it's pid.
               ip,  % Ip of peer in question
               port :: non_neg_integer(), % Port of peer in question
               torrent_id :: non_neg_integer(), % (IDX) Torrent Id this peer belongs to
               state :: 'seeding' | 'leeching'}).


