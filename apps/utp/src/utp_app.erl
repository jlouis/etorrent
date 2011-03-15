%%% @author Jesper Louis andersen <jesper.louis.andersen@gmail.com>
%%% @copyright (C) 2011, Jesper Louis andersen
%%% @doc The UTP application driver
%%% @end
-module(utp_app).

-behaviour(application).

%% Application callbacks
-export([start/0, start/2, stop/1]).

%%%===================================================================
%%% Application callbacks
%%%===================================================================

%% @doc Manual startup of the uTP application
start() ->
    ok = ensure_started([sasl, gproc]),
    application:start(utp).

ensure_started([]) ->
    ok;
ensure_started([App | R]) ->
    case application:start(App) of
	ok ->
	    ensure_started(R);
	{error, {already_started, App}} ->
	    ensure_started(R)
    end.

%% @private
start(_StartType, _StartArgs) ->
    case utp_sup:start_link(3333) of
        {ok, Pid} ->
            {ok, Pid};
        {error, Reason} ->
            {error, Reason}
    end.

%% @private
stop(_State) ->
    ok.
