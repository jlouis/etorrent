%% The rate record is used for recording information about rates
%%   on torrents
-record(peer_rate, { rate = 0.0           :: float(),
                     total = 0            :: integer(),
                     next_expected = none :: none | integer(),
                     last = none          :: none | integer(),
                     rate_since = none    :: none | integer()}).

-define(RATE_UPDATE, 5 * 1000).
-define(RATE_FUDGE, 5).
