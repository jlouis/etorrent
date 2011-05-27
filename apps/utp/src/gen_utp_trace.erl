%%% @author Jesper Louis andersen <jesper.louis.andersen@gmail.com>
%%% @copyright (C) 2011, Jesper Louis andersen
%%% @doc Trace events in the uTP stack
%%% @end
-module(gen_utp_trace).

-behaviour(gen_server).

%% API
-export([start_link/0,
         grab/0,
         tr/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE). 

-record(state, { trace_buffer = [] :: [term()] }).

%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

tr(Msg) ->
    gen_server:cast(?SERVER, {trace, Msg}).

grab() ->
    gen_server:call(?SERVER, grab).

%%%===================================================================

%% @private
init([]) ->
    {ok, #state{ trace_buffer = [] }}.

%% @private
handle_call(grab, _From, #state { trace_buffer = TB } = State) ->
    {reply, {ok, lists:reverse(TB)}, State#state { trace_buffer = [] }};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%% @private
handle_cast({trace, Msg}, #state { trace_buffer = TB } = State) ->
    {noreply, State#state { trace_buffer = [Msg | TB] }};
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
