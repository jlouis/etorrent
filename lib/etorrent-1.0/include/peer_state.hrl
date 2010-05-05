-record(peer_state, {pid,
                     choke_state = choked,
                     interest_state = not_interested,
                     local_choke = true}).
