%%% @author Jesper Louis andersen <jesper.louis.andersen@gmail.com>
%%% @copyright (C) 2011, Jesper Louis andersen
%%% @doc The UTP application driver
%%% @end
-module(utp_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%%%===================================================================
%%% Application callbacks
%%%===================================================================

%% @private
start(_StartType, _StartArgs) ->
    case utp_sup:start_link(1729) of
        {ok, Pid} ->
            {ok, Pid};
        Error ->
            Error
    end.

%% @private
stop(_State) ->
    ok.
