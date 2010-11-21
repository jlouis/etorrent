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

-ignore_xref({start_link, 2}).

%% ====================================================================
% @doc start a file-maintenance process
%   <p>The file has Id in the path-map and belongs to TorrentId</p>
% @end
-spec start_link(string(), integer()) -> 'ignore' | {'ok', pid()} | {'error', any()}.
start_link(Id, TorrentId) ->
    gen_server:start_link(?MODULE, [Id, TorrentId], []).

% @doc Read data the file maintained by Pid at Offset and Size bytes
% from that offset point. 
% @end
-spec read(pid(), integer(), integer()) -> {ok, binary()}.
read(Pid, OffSet, Size) ->
    gen_server:call(Pid, {read, OffSet, Size}).

% @doc Write Chunk to the file maintained by Pid at Offset. The Size
% field is currently ignored.
% @end
-spec write(pid(), binary(), integer(), integer()) -> ok.
write(Pid, Chunk, Offset, _Size) ->
    gen_server:call(Pid, {write, Offset, Chunk}).

% @doc stop the file maintained by Pid
% @end
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:cast(Pid, stop).

%% ====================================================================
init([Id, TorrentId]) ->
    %% We'll clean up file descriptors gracefully on termination.
    process_flag(trap_exit, true),
    etorrent_fs_janitor:new_fs_process(self()),
    {ok, Path} = etorrent_table:get_path(Id, TorrentId),
    {ok, Workdir} = application:get_env(etorrent, dir),
    FullPath = filename:join([Workdir, Path]),
    {ok, IODev} = file:open(FullPath, [read, write, binary, raw, read_ahead,
				       {delayed_write, 1024*1024, 3000}]),
    {ok, #state{iodev = IODev,
                path = FullPath}, ?REQUEST_TIMEOUT}.

handle_call({read, Offset, Size}, _From, #state { iodev = IODev} = State) ->
    etorrent_fs_janitor:bump(self()),
    {ok, Data} = file:pread(IODev, Offset, Size),
    {reply, {ok, Data}, State, ?REQUEST_TIMEOUT};
handle_call({write, Offset, Data}, _From, #state { iodev = IODev } = S) ->
    etorrent_fs_janitor:bump(self()),
    ok = file:pwrite(IODev, Offset, Data),
    {reply, ok, S, ?REQUEST_TIMEOUT};
handle_call(Msg, _From, S) ->
    ?WARN({unknown_msg, ?MODULE, Msg}),
    {reply, ok, S, ?REQUEST_TIMEOUT}.

handle_cast(stop, S) ->
    {stop, normal, S};
handle_cast(Msg, State) ->
    ?WARN([unknown_cast, Msg]),
    {noreply, State, ?REQUEST_TIMEOUT}.

handle_info(timeout, State) ->
    {stop, normal, State};
handle_info(Info, State) ->
    ?WARN([unknown_info_msg, Info]),
    {noreply, State}.

terminate(_Reason, State) ->
    case file:close(State#state.iodev) of
        ok -> ok;
        E -> ?WARN([cant_close_file, E]), ok
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
