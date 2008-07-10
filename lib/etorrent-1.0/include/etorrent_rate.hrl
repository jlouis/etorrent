%% The rate record is used for recording information about rates
%%   on torrents
-record(peer_rate, { rate = 0.0,
		     total = 0,
		     next_expected = none,
		     last = none,
		     rate_since = none }).
