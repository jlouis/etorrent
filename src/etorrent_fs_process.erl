%%%-------------------------------------------------------------------
%%% File    : file_process.erl
%%% Author  : User Jlouis <jesper.louis.andersen@gmail.com>
%%% License : See COPYING
%%% Description : The file process implements an interface to a given
%%%  file. It is possible to carry out the wished operations on the file
%%%  in question for operating in a Torrent Client. The implementation has
%%%  an automatic handler for file descriptors: If no request has been
%%%  received in a given timeout, then the file is closed.
%%%
%%% Created : 18 Jun 2007 by User Jlouis <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_fs_process).

-include("etorrent_mnesia_table.hrl").
-include("log.hrl").

-behaviour(gen_server).

%% API
-export([start_link/2, read/3, write/4, stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {path = none,
                iodev = none}).

% If no request has been received in this interval, close the server.
-define(REQUEST_TIMEOUT, timer:seconds(60)).

%% ====================================================================
%% @doc start a file-maintenance process of the file at Path. Id is the
%% torrent Id it is running on.
-spec start_link(string(), integer()) -> 'ignore' | {'ok', pid()} | {'error', any()}.
start_link(Path, Id) ->
    gen_server:start_link(?MODULE, [Path, Id], []).

%% @doc Read data the file maintained by Pid at Offset and Size bytes
%% from that offset point. 
-spec read(pid(), integer(), integer()) -> {ok, binary()}.
read(Pid, OffSet, Size) ->
    gen_server:call(Pid, {read, OffSet, Size}).

%% @doc Write Chunk to the file maintained by Pid at Offset. The Size
%% field is currently ignored.
-spec write(pid(), binary(), integer(), integer()) -> ok.
write(Pid, Chunk, Offset, _Size) ->
    gen_server:call(Pid, {write, Offset, Chunk}).

%% @doc stop the file maintained by Pid
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:cast(Pid, stop).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Id, TorrentId]) ->
    %% We'll clean up file descriptors gracefully on termination.
    process_flag(trap_exit, true),
    etorrent_fs_janitor:new_fs_process(self()),
    #path_map { path = Path} = etorrent_path_map:select(Id, TorrentId),
    {ok, Workdir} = application:get_env(etorrent, dir),
    FullPath = filename:join([Workdir, Path]),
    {ok, IODev} = file:open(FullPath, [read, write, binary, raw, read_ahead]),
    {ok, #state{iodev = IODev,
                path = FullPath}, ?REQUEST_TIMEOUT}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({read, Offset, Size}, _From, State) ->
    etorrent_fs_janitor:bump(self()),
    Data = read_request(Offset, Size, State),
    {reply, {ok, Data}, State, ?REQUEST_TIMEOUT};
handle_call({write, Offset, Data}, _From, S) ->
    etorrent_fs_janitor:bump(self()),
    ok = write_request(Offset, Data, S),
    {reply, ok, S, ?REQUEST_TIMEOUT}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(stop, S) ->
    {stop, normal, S};
handle_cast(_Msg, State) ->
    {noreply, State, ?REQUEST_TIMEOUT}.

handle_info(timeout, State) ->
    {stop, normal, State};
handle_info(Info, State) ->
    error_logger:warning_report([unknown_fs_process, Info]),
    {noreply, State}.

terminate(_Reason, State) ->
    case file:close(State#state.iodev) of
        ok -> ok;
        E -> ?log([cant_close_file, E]), ok
    end.

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
    {ok, NP} = file:position(State#state.iodev, Offset),
    Offset = NP,
    {ok, Data} = file:read(State#state.iodev, Size),
    Data.

%%--------------------------------------------------------------------
%% Func: write_request(Offset, Bytes, State) -> ok
%%                                            | {pos_error, posix()}
%%                                            | {write_error, posix()}
%% Description: Attempt to write Bytes at offset Offset. Either returns
%%   ok, or an error from positioning or writing which is posix().
%%--------------------------------------------------------------------
write_request(Offset, Bytes, State) ->
    {ok, NP} = file:position(State#state.iodev, Offset),
    Offset = NP,
    ok = file:write(State#state.iodev, Bytes).

%%--------------------------------------------------------------------
%% Func:
%% Description:
%%--------------------------------------------------------------------
