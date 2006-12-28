-module(torrent).
-compile(export_all).
-author("jesper.louis.andersen@gmail.com").

init() ->
    %%Get access to the inets application
    application:start(inets).

