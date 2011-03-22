-module(etorrent_endgame).
-behaviour(gen_server).

%% gen_server callbacks
-export([init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3]).

init('_') -> ok.
handle_call('_', '_', '_') -> ok.
handle_cast('_', '_') -> ok.
handle_info('_', '_') -> ok.
terminate('_', '_') -> ok.
code_change('_', '_', '_') -> ok.
