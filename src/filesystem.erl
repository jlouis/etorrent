-module(filesystem).
-behaviour(gen_server).

-export([init/1, handle_cast/2, handle_call/3, terminate/2, handle_info/2, code_change/3]).

-export([start_link/0, request_piece/4]).

-record(fs_state, {completed = 0}).

init(_Arg) ->
    {ok, #fs_state{}}.

handle_cast({piece, _PieceData}, State) ->
    {noreply, State}.

handle_call(completed_amount, _Who, State) ->
    {reply, State#fs_state.completed, State}.

handle_info(Info, State) ->
    error_logger:error_report(Info, State).

terminate(shutdown, _Reason) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% functions
start_link() ->
    gen_server:start_link(filesystem, no, []).

request_piece(Pid, Index, Begin, Len) ->
    %% Retrieve data from the file system for the requested bit.
    gen_server:call(Pid, {request_piece, Index, Begin, Len}).
