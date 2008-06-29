-record(tracking_map, {id,  %% Unique identifier of torrent
		       filename, %% The filename
		       supervisor_pid,%% The Pid of who is supervising the torrent
		       info_hash, %% Info hash of the torrent in question. May be unknown.
		       state}). %% started | stopped | checking | awaiting_check

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
		  state}). % What is our state: leecher | unknown | seeder

%% Counter for how many pieces is missing from this torrent
-record(torrent_c_pieces, {id, % Torrent id
			   missing}). % Number of missing pieces

%% The peer record represents a peer we are talking to
-record(peer, {pid, % We identify each peer with it's pid.
	       ip,  % Ip of peer in question
	       port, % Port of peer in question
	       torrent_id, % Torrent Id this peer belongs to
	       uploaded = 0, % Amount of uploaded bytes this round
	       downloaded = 0, % Amount of downloaded bytes this round
	       remote_i_state = not_interested, % Is this peer interested in us?
	       remote_c_state = choked, % true if the remote is choking us.
	       optimistic_c_state = not_opt_unchoke}). % true if we have selected this peer for opt. unchoke

%% Individual pieces are represented via the piece record
-record(piece, {idpn, % {Id, PieceNumber} pair identifying the piece
	        hash, % Hash of piece
		id, % Id of this piece owning this piece, again for an index
		piece_number, % Piece Number of piece, replicated for fast qlc access
		files, % File operations to manipulate piece
		left = unknown, % Number of chunks left...
		state}). % state is: fetched | not_fetched | chunked

%% A mapping containing the chunks tracking
-record(chunk, {idt, % {id, piece_number, state} tuple
		     % state is fetched | {assigned, Pid} | not_fetched,
		chunks}). % {offset, size}

-record(chunk_data, {idt, % {id, piece_number, offset}
		     data}). % The chunk data, if exists



