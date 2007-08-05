{application, etorrent,
[{description, "BitTorrent client in Erlang"},
 {vsn, "1.0"},
 {modules, [bcoding, dirwatcher, etorrent, peer_communication,
            torrent_manager, torrent_peer,
	    torrent_state, tracker_delegate,
	    metainfo, utils]},
 {registered, [torrent_manager, dirwatcher]},
 {applications, [kernel, stdlib, inets, crypto]},
 {mod, {etorrent_app,[]}},
 {env, [{dir, "./test"},
        {port, 1729}]}]}.

