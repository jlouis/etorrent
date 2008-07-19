%% A bad peer record is capturing bad peers
-record(bad_peer, { ipport :: tuple(), % {IP, Port} pair
		    offenses :: integer() , % integer(),
		    last_offense }). % When the last offense happened.

