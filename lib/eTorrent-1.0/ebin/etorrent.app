{application, etorrent,
[{description, "BitTorrent client in Erlang"},
 {vsn, "1"},
 {modules, [bcoding, dirwatcher, etorrent, filesystem, peer_communication,
            torrent, torrent_manager, torrent_manager_sup, torrent_peer,
	    torrent_piecemap, torrent_state, tracker_delegate,
	    connection_manager, metainfo, utils]},
 {registered, [torrent_manager, dirwatcher]},
 {applications, [kernel, stdlib, inets, crypto]},
 {mod, {etorrent_app,[]},
 {env, [{dir, "./test"}]}}
]}.
