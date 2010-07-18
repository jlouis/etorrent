%% Various types spanning multiple modules.

-type operation() :: {integer(), integer(), integer()}.
-type bitfield() :: binary().
-type ip() :: {integer(), integer(), integer(), integer()}.

% The bcode() type:
-type bstring() :: {'string', string()}.
-type binteger() :: {'integer', integer()}.
-type bcode() :: bstring()
               | binteger()
               | {'list', [bcode()]}
               | {'dict', [{bstring(), bcode()}]}.

% Event you can send to the tracker.
-type tracker_event() :: completed | started | stopped.
