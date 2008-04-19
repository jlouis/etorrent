-record(tracking_map, {filename,
		       supervisor_pid}).

%% A single torrent is represented as the 'torrent' record
-record(torrent, {info_hash, % Info hash of the torrent
		  storer_pid, % Which pid is responsible for it
		  left, % How many bytes are there left before we have the full torrent
		  uploaded, % How many bytes have we uploaded
		  downloaded, % How many bytes have we downloaded
		  complete = 0, % How many people have a completed file?
		  incomplete = 0, % How many people are downloaded
		  state}). % What is our state: leecher | unknown | seeder


-record(peer_info, {id,
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

%% Histogram entries
-record(histogram, {ref, % unique reference
		    pid, % pid owning the histogram entry
		    todo}).

%% Individual pieces are represented via the file_access record
-record(file_access, {hash, % Hash of piece
		      piece_number, % piece number index
		      pid, % Pid owning this piece
		      files, % File operations to manipulate piece
		      left = unknown, % Number of chunks left...
		      state}). % state is: fetched | not_fetched | chunked

%% A 16K chunk of data
-record(chunk, {ref, % unique reference
		pid, % Pid owning this chunk, referers to file_access.pid
		piece_number, % piece_number this chunk belongs to
		offset, % Offset of chunk in the piece
		size, % size of chunk in the piece (almost always 16K, but last piece may differ)
		assign = unknown, % Aux data for piece
		state}). % state is: fetched | not_fetched | assigned



