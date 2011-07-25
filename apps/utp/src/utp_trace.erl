%%%-------------------------------------------------------------------
%%% @author Jesper Louis andersen <>
%%% @copyright (C) 2011, Jesper Louis andersen
%%% @doc Trace counters for connections
%%% @end
%%% Created : 25 Jul 2011 by Jesper Louis andersen <>
%%%-------------------------------------------------------------------
-module(utp_trace).

-behaviour(gen_server).

-include("log.hrl").

%% API
-export([
         close_all/0,

         start_link/1,
         trace/2
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE). 

-record(state, { enabled = false :: boolean(),
                 map = dict:new():: dict() }).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Starts the server
%% @end
%%--------------------------------------------------------------------
start_link(Options) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Options], []).

trace(Counter, Count) ->
    Now = erlang:now(),
    gen_server:cast(?SERVER, {trace_point, Now, self(), Counter, Count}).

close_all() ->
    gen_server:cast(?SERVER, close_all).

%%%===================================================================

%% @private
init([Options]) ->
    case proplists:get_value(trace_counters, Options) of
        true ->
            {ok, #state { enabled = true,
                          map = dict:new() }};
        undefined -> {ok, #state{ enabled = false}}
    end.

%% @private
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%% @private
handle_cast(_Msg, #state { enabled = false } = State) ->
    {noreply, State};
handle_cast({trace_point, TimeStamp, Connection, Counter, Count},
            #state { enabled = true, map = Map } = State) ->
    {N_Map, Handle} = find_handle({Connection, Counter}, Map),
    trace_message(Handle, format_message(TimeStamp, Count)),
    {noreply, State#state { map = N_Map }};
handle_cast(close_all, #state { enabled = true, map = M }) ->
    [file:close(H) || {_K, H} <- dict:to_list(M)],
    #state { enabled = ture,
             map = dict:new() };
handle_cast(Msg, State) ->
    ?ERR([unknown_handle_case, Msg, State]),
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

find_handle({Connection, Counter} = Id, Map) when is_atom(Counter) ->
    case dict:find(Id, Map) of
        error ->
            find_handle(Id,
                        dict:store({Connection, Counter},
                                   create_handle(Connection, Counter), Map));
        {ok, Handle} ->
            {Map, Handle}
    end.

format_conn(Connection) ->
    pid_to_list(Connection).

create_handle(Connection, Counter) ->
    FName = [os:getpid(), "-", format_conn(Connection), "-", atom_to_list(Counter)],
    {ok, Handle} = file:open(FName, [write, raw, binary, {delayed_write, 8192, 3000}]),
    Handle.

format_message({Mega, Secs, Micro}, Count) ->
    Time = [Mega*1000000+Secs, ".", io_lib:format("~6..0B", [Micro])],
    CountS = integer_to_list(Count),
    [Time, $|, CountS, $\n].

trace_message(Handle, Event) ->
    ok = file:write(Handle, Event).





