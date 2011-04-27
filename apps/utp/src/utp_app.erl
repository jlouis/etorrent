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
    Port = case application:get_env(utp, udp_port) of
               {ok, P} -> P;
               undefined  -> 3333
           end,
    case utp_sup:start_link(Port) of
        {ok, Pid} ->
            {ok, Pid};
        {error, Reason} ->
            {error, Reason}
    end.

%% @private
stop(_State) ->
    ok.
