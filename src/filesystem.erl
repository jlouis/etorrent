-module(filesystem).
-behaviour(gen_server).

-export([init/1, handle_cast/2, handle_call/3,
	 terminate/2, handle_info/2, code_change/3]).

-export([start_link/0, request_piece/4]).

-record(fs_state, {completed = 0,
		   piecelength = none,
		   piecemap = none,
		   data = none}).

init(Torrent) ->
    PieceMap = build_piecemap(metainfo:get_pieces(Torrent)),
    PieceLength = metainfo:get_piece_length(Torrent),
    Disk = dets:new(disk_data, []),
    {ok, #fs_state{piecemap = PieceMap,
		   piecelength = PieceLength,
		   data = Disk}}.

build_piecemap(Pieces) ->
    ZL = lists:zip(lists:seq(1, length(Pieces)), Pieces),
    dict:from_list(ZL).

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
