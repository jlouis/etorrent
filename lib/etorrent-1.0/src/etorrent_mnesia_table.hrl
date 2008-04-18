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

-record(file_access, {hash,
		      piece_number,
		      pid,
		      files,
		      left = unknown, % Number of chunks left...
		      state}). % state is: fetched | not_fetched | chunked

-record(chunk, {ref,
		pid, % Refers to file_access
		piece_number,
		offset,
		size,
		assign = unknown,
		state}). % state is: fetched | not_fetched | assigned



