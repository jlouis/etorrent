-record(tracking_map, {id,  %% Unique identifier of torrent
		       filename, %% The filename
		       supervisor_pid,%% The Pid of who is supervising the torrent
		       info_hash %% Info hash of the torrent in question. May be unknown.
		      }).

%% A single torrent is represented as the 'torrent' record
-record(torrent, {id, % Unique identifier of torrent, monotonically increasing
		      %   foreign keys to tracking_map.id
		  left, % How many bytes are there left before we have the full torrent
		  uploaded, % How many bytes have we uploaded
		  downloaded, % How many bytes have we downloaded
		  seeders = 0, % How many people have a completed file?
		  leechers = 0, % How many people are downloaded
		  state}). % What is our state: leecher | unknown | seeder


-record(peer_info, {id, % Each peer is identified by its peer_id here
		    uploaded,
		    downloaded,
		    interested,
		    remote_choking,
		    optimistic_unchoke}).

-record(peer_map, {pid,
		   ip,
		   port,
		   info_hash}).

-record(peer,     {map,
		   info}).

%% Individual pieces are represented via the piece record
-record(piece, {hash, % Hash of piece
		      piece_number, % piece number index
		      id, % Id of this piece owning this piece
		      files, % File operations to manipulate piece
		      frequency = 0, % How often does this piece occur at others?
		      left = unknown, % Number of chunks left...
		      state}). % state is: fetched | not_fetched | chunked

%% A 16K chunk of data
-record(chunk, {ref, % unique reference
		id, % id owning this chunk, referers to piece.id
		piece_number, % piece_number this chunk belongs to
		offset, % Offset of chunk in the piece
		size, % size of chunk in the piece (almost always 16K, but last piece may differ)
		assign = unknown, % Aux data for piece
		state}). % state is: fetched | not_fetched | assigned



