%%%-------------------------------------------------------------------
%%% @author Jesper Louis andersen <>
%%% @copyright (C) 2011, Jesper Louis andersen
%%% @doc Trace counters for connections
%%% @end
%%% Created : 25 Jul 2011 by Jesper Louis andersen <>
%%%-------------------------------------------------------------------
-module(utp_trace).

-behaviour(gen_server).

%% API
-export([
         start_link/1,
         trace/3
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE). 

-record(state, { enabled = false :: boolean() }).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Starts the server
%% @end
%%--------------------------------------------------------------------
start_link(Options) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Options], []).

trace(Connection, Counter, Count) ->
    Now = erlang:now(),
    gen_server:cast(?SERVER, {trace_point, Now, Connection, Counter, Count}).

%%%===================================================================

%% @private
init([Options]) ->
    case proplists:get_value(trace_counters, Options) of
        true ->
            {ok, #state { enabled = true }};
        undefined -> {ok, #state{ enabled = false}}
    end.

%% @private
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%% @private
handle_cast(_Msg, #state { enabled = false } = State) ->
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
