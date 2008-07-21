%% Sequences, as in SQL SEQUENCES
-record(sequence, {name, count}).

%% The tracking map tracks torrent id's to filenames, etc. It is the high-level view
-record(tracking_map, {id,  %% Unique identifier of torrent
		       filename, %% The filename
		       supervisor_pid,%% The Pid of who is supervising the torrent
		       info_hash, %% Info hash of the torrent in question. May be unknown.
		       state}). %% started | stopped | checking | awaiting_check

%% The path map tracks file system paths and maps them to integers.
-record(path_map, {id,    % Unique Id of pathmap: a pair {sequence.id, Torrent_id}
		   path}). % (IDX) File system path minus work dir

%% A single torrent is represented as the 'torrent' record
-record(torrent, {id, % Unique identifier of torrent, monotonically increasing
		      %   foreign keys to tracking_map.id
		  left, % How many bytes are there left before we have the
		        % full torrent
		  total, % How many bytes are there in total
		  uploaded, % How many bytes have we uploaded
		  downloaded, % How many bytes have we downloaded
		  pieces = unknown, % Number of pieces this torrent has
		  seeders = 0, % How many people have a completed file?
		  leechers = 0, % How many people are downloaded
		  state}). % What is our state: leecher | unknown | seeder | endgame

%% Counter for how many pieces is missing from this torrent
-record(torrent_c_pieces, {id, % Torrent id
			   missing}). % Number of missing pieces

%% The peer record represents a peer we are talking to
-record(peer, {pid, % We identify each peer with it's pid.
	       ip,  % Ip of peer in question
	       port, % Port of peer in question
	       torrent_id}). % (IDX) Torrent Id this peer belongs to


%% Piece state on disk for persistence
-record(piece_diskstate, {filename, % Name of torrent
			  state}). % state | {bitfield, BF}

