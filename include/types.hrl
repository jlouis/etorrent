%% Various types spanning multiple modules.

-type operation() :: {integer(), integer(), integer()}.
-type bitfield() :: binary().

% The bcode() type:
-type bstring() :: {'string', string()}.
-type binteger() :: {'integer', integer()}.
-type bcode() :: bstring()
               | binteger()
               | {'list', [bcode()]}
               | {'dict', [{bstring(), bcode()}]}.
