-record(tracking_map, {filename,
		       supervisor_pid}).

-record(info_hash, {info_hash,
		    storer_pid,
		    monitor_reference,
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
		   infohash,
		   peer_info_id}).

-record(peer,     {map,
		   info}).

