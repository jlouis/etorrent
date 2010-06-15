-module(etorrent_webui).

-export([list/3]).


list(SessID, _Env, _Input) ->
    mod_esi:deliver(SessID, "<p>This data stems from Erlang!</p>").

