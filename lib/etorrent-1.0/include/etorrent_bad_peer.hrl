%% A bad peer record is capturing bad peers
-record(bad_peer, { ipport, % {IP, Port} pair
		    offenses, % integer(),
		    last_offense }). % When the last offense happened.

