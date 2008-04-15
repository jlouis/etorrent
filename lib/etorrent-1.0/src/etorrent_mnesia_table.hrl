-record(tracking_map, {filename,
		       supervisor_pid}).

-record(info_hash, {info_hash,
		    storer_pid,
		    state}).


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



