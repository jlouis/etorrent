%% @doc Serve the jQuery front end with AJAX responses
%% <p>This module exists solely to serve the jQuery frontend with
%% responses to its AJAX requests. Basically, a jQuery script is
%% statically served and then that script callbacks to this module to
%% get the updates. That way, we keep static and dynamic data nicely split.
%% </p>
%% @end
-module(etorrent_webui).

-include("etorrent_version.hrl").
-export([
        ]).

-ignore_xref([{list, 3}, {log, 3}]).
%% =======================================================================



