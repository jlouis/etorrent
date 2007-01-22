-module(connection_manager).
-behaviour(gen_server).

-export([handle_call/3, init/1, terminate/2, code_change/3, handle_info/2, handle_cast/2]).
-export([is_interested/2, is_not_interested/2, start_link/0]).

start_link() ->
    gen_server:start_link(connection_manager, none, []).

init(_Args) ->
    {ok, ets:new(connection_table, [])}.

handle_info(Message, State) ->
    error_logger:error_report([Message, State]),
    {noreply, State}.

handle_call(Message, Who, State) ->
    error_logger:error_msg("M: ~s -- F: ~s~n", [Message, Who]),
    {noreply, State}.

terminate(shutdown, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_cast({is_interested, PeerId}, State) ->
    {noreply, ets:insert_new(State, {PeerId, interested})};
handle_cast({is_not_interested, PeerId}, State) ->
    {norelpy, ets:insert_new(State, {PeerId, not_interested})}.

is_interested(Pid, PeerId) ->
    gen_server:cast(Pid, {is_interested, PeerId}).

is_not_interested(Pid, PeerId) ->
    gen_server:cast(Pid, {is_not_intersted, PeerId}).
