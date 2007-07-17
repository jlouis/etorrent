%%%-------------------------------------------------------------------
%%% File    : file_process.erl
%%% Author  : User Jlouis <jlouis@succubus.localdomain>
%%% Description : The file process implements an interface to a given
%%%  file. It is possible to carry out the wished operations on the file
%%%  in question for operating in a Torrent Client. The implementation has
%%%  an automatic handler for file descriptors: If no request has been
%%%  recieved in a given timeout, then the file is closed.
%%%
%%% Created : 18 Jun 2007 by User Jlouis <jlouis@succubus.localdomain>
%%%-------------------------------------------------------------------
-module(file_process).

-behaviour(gen_server).

%% API
-export([start_link/1, get_data/3, put_data/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {path = none,
		iodev = none}).

% If no request has been recieved in this interval, close the server.
-define(REQUEST_TIMEOUT, 60000).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(Path) ->
    gen_server:start_link(?MODULE, [Path], []).

get_data(Pid, OffSet, Size) ->
    gen_server:call(Pid, {read_request, OffSet, Size}).

put_data(Pid, Chunk, Offset, _Size) ->
    gen_server:call(Pid, {write_request, Offset, Chunk}).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Path]) ->
    case file:open(Path, [read, write, binary, raw]) of
	{ok, IODev} ->
	    {ok, #state{iodev = IODev,
		        path = Path}, ?REQUEST_TIMEOUT};
	{error, Reason} ->
	    {stop, Reason}
    end.


%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({read_request, OffSet, Size}, _From, State) ->
    case read_request(OffSet, Size, State) of
	{ok, Data} ->
	    {reply, {ok, Data}, State, ?REQUEST_TIMEOUT};
	{pos_error, E} ->
	    {stop, E, error, State};
	{read_error, E} ->
	    {stop, E, error, State}
    end;
handle_call({write_request, OffSet, Data}, _From, S) ->
    case write_request(OffSet, Data, S) of
	ok ->
	    {reply, ok, S, ?REQUEST_TIMEOUT};
	{pos_error, E} ->
	    {stop, E, error, S};
	{write_error, E} ->
	    {stop, E, error, S}
    end.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State, ?REQUEST_TIMEOUT}.

handle_info(timeout, State) ->
    {stop, normal, State};
handle_info(Info, State) ->
    io:format("Unknown: ~w", [Info]),
    {noreply, State}.

terminate(_Reason, State) ->
    file:close(State#state.iodev),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Func: read_request(Offset, Size, State) -> {ok, Data}
%%                                          | {read_error, posix()}
%%                                          | {pos_error, posix()}
%% Description: Attempt to read at Offset; Size bytes. Either returns
%%  ok or an error from the positioning or reading with a posix()
%%  error message.
%%--------------------------------------------------------------------
read_request(Offset, Size, State) ->
    case file:position(State#state.iodev, Offset) of
	{error, PosixReason} ->
	    {pos_error, PosixReason};
	{ok, NP} ->
	    Offset = NP,
	    case file:read(State#state.iodev, Size) of
		{error, Reason} ->
		    {read_error, Reason};
		eof ->
		    {read_error, eof};
		{ok, Data} ->
		    {ok, Data}
	    end
    end.

%%--------------------------------------------------------------------
%% Func: write_request(Offset, Bytes, State) -> ok
%%                                            | {pos_error, posix()}
%%                                            | {write_error, posix()}
%% Description: Attempt to write Bytes at offset Offset. Either returns
%%   ok, or an error from positioning or writing which is posix().
%%--------------------------------------------------------------------
write_request(Offset, Bytes, State) ->
    case file:position(State#state.iodev, Offset) of
	{error, R} ->
	    {pos_error, R};
	{ok, _NP} ->
	    case file:write(State#state.iodev, Bytes) of
		{error, R} ->
		    {write_error, R};
		ok ->
		    ok
	    end
    end.

%%--------------------------------------------------------------------
%% Func:
%% Description:
%%--------------------------------------------------------------------
