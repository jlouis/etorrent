%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @author Uvarov Michail <freeakk@gmail.com>
%% @doc Chunk manager of a torrent.
%%-------------------------------------------------------------------
-module(etorrent_reordered).
-behaviour(gen_server).
-define(LOG(X), io:write(X)).

-include_lib("stdlib/include/ms_transform.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% peer API
-export([start_link/3,
        monitor_chunks/2]).


%% gproc registry entries
-export([register_server/1,
         unregister_server/1,
         lookup_server/1,
         await_server/1]).


%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).



-type pieceset()   :: etorrent_pieceset:pieceset().
-type torrent_id() :: etorrent_types:torrent_id().
-type chunk_len() :: etorrent_types:chunk_len().
-type piece_index() :: etorrent_types:piece_index().
-type chunk() :: {piece_index(), non_neg_integer(), non_neg_integer()}.
-type chunkset()   :: etorrent_chunkset:chunkset().

-record(wish, {
    ref :: reference(),
    pid :: pid(),
    chunks :: [chunk()]
}).

-type wish() :: #wish{}.


-record(state, {
    torrent_id  :: pos_integer(),
    piece_size :: non_neg_integer(),
    chunk_size :: non_neg_integer(),
    chunk_len :: chunk_len(),
    chunkset :: chunkset(),

    %% These parts are already downloaded.
    valid_pieces :: pieceset(),
    valid_chunks :: array(), % of chunkset()

    %% We want them, but nobody is assigned on them.
    wanted_pieces :: pieceset(),
    wanted_chunks :: array(), 

    %% List of assigned but not stored yet wanted parts.
    %% We will check them in cron.
    lefted_pieces :: pieceset(),
    lefted_chunks :: array(),

    monitored_chunks :: [wish()],
    interval    :: timer:interval()
}).


-spec register_server(torrent_id()) -> true.
register_server(TorrentID) ->
    etorrent_utils:register(server_name(TorrentID)).

-spec unregister_server(torrent_id()) -> true.
unregister_server(TorrentID) ->
    etorrent_utils:unregister(server_name(TorrentID)).

-spec lookup_server(torrent_id()) -> pid().
lookup_server(TorrentID) ->
    etorrent_utils:lookup(server_name(TorrentID)).

-spec await_server(torrent_id()) -> pid().
await_server(TorrentID) ->
    etorrent_utils:await(server_name(TorrentID)).

server_name(TorrentID) ->
    {etorrent, TorrentID, reordered_server}.


%% @doc Start a new torrent progress server
%% @end
start_link(TorrentId, ValidPieceSet, ValidChunkArr) ->
    Args = [TorrentId, ValidPieceSet, ValidChunkArr],
    gen_server:start_link(?MODULE, Args, []).


monitor_chunks(ChunkSrv, Chunks) ->
    gen_server:call(ChunkSrv, {monitor_chunks, Chunks}).


%% @private

init([TorrentID, ValidPieceSet, ValidChunkArr]) ->
    true = register_server(TorrentID),
    true = etorrent_download:register_server(TorrentID),
    Pending = etorrent_pending:await_server(TorrentID),
    ok = etorrent_pending:receiver(self(), Pending),
    PCount = etorrent_info:piece_count(TorrentID),
    CSize = etorrent_info:chunk_size(TorrentID),
    PSize = etorrent_info:piece_size(TorrentID),
    {ok, Timer} = timer:send_interval(5000, check_completed),
    ChunkSetPrototype = etorrent_chunkset:from_list(PSize, CSize, []),

    State = #state{
        torrent_id=TorrentID,

        piece_size=PSize,
        chunk_size=CSize,
        chunkset=ChunkSetPrototype,

        valid_pieces=ValidPieceSet,
        valid_chunks=ValidChunkArr,
        wanted_pieces=etorrent_pieceset:empty(PCount),
        wanted_chunks=array:new(),
        lefted_pieces=etorrent_pieceset:empty(PCount),
        lefted_chunks=array:new(),
        monitored_chunks=[],
        interval=Timer
    },
    {ok, State}.


%% This function will be called by `etorrent_ebml'.
handle_call({monitor_chunks, ChunkList}, {Pid, _Ref}, State) ->
    #state{
        chunkset=ChunkSetPrototype,
        wanted_pieces=WantedPieceSet,
        wanted_chunks=WantedChunkArr,
        lefted_pieces=LeftedPieceSet,
        lefted_chunks=LeftedChunkArr,
        valid_pieces=ValidPieceSet,
        valid_chunks=ValidChunkArr,
        monitored_chunks=Monitored,
        piece_size=PSize,
        chunk_size=CSize} = State,

    case difference(ChunkList, ValidPieceSet, ValidChunkArr) of
    [] -> {reply, completed, State};
    NewChunkList ->

%       Ref = erlang:monitor(process, Pid),
        Ref = erlang:make_ref(),

        {NewWantedPieceSet, NewWantedChunkArr} = insert_chunks(
            NewChunkList, WantedPieceSet, WantedChunkArr, ChunkSetPrototype),
        {NewLeftedPieceSet, NewLeftedChunkArr} = insert_chunks(
            NewChunkList, LeftedPieceSet, LeftedChunkArr, ChunkSetPrototype),

        Query = #wish{
            pid = Pid,
            ref = Ref,
            chunks = NewChunkList
        },

        NewState = State#state{
            wanted_pieces=NewWantedPieceSet,
            wanted_chunks=NewWantedChunkArr,
            lefted_pieces=NewLeftedPieceSet,
            lefted_chunks=NewLeftedChunkArr,
            monitored_chunks=[Query|Monitored]},

        ?LOG({r, o, ChunkList}),
        {reply, {subscribed, Ref}, NewState}
    end;


handle_call({chunk, {request, Numchunks, PeerSet, _PeerPid}}, _, State) ->
    ?LOG({r, q, Numchunks}),
    #state{
        wanted_pieces=PieceSet,
        wanted_chunks=ChunkArr} = State,

    case etorrent_pieceset:size(PieceSet) of
        %% If the queue is empty, then the manager will call 
        %% `etorrent_peer_control:update_queue(PeerPid)'
        %% when new wanted pieces will appear.
        %% It will call this function again with the same message 
        %% `{chunk, {request'.
        %% We can calculate how many chunks we can request in the future.
        0 -> {reply, {ok, assigned}, State};
        _ -> 
            Valid = etorrent_pieceset:intersection(PeerSet, PieceSet),
            {Left, NewChunkArr, ChunkList} = 
                retrieve_chunks(Numchunks, Valid, ChunkArr, []),
            Deleted = etorrent_pieceset:difference(Valid, Left),
            NewPieceSet = etorrent_pieceset:difference(PieceSet, Deleted),

            NewState = State#state{
                wanted_pieces=NewPieceSet,
                wanted_chunks=NewChunkArr},

            ?LOG({r, w, ChunkList}),
            {reply, {ok, ChunkList}, NewState}
    end.


%% @private
%% wish part of the piece
handle_cast(_, State) ->
    {stop, not_implemented, State}.


%% @private
handle_info({chunk, {fetched,Index,Offset, Length,_PeerPid}}, State) ->
%   ?LOG({r, cf, Index, Offset, Length}),
    {noreply, State};

handle_info({chunk, {stored,Index,Offset,Length,_PeerPid}}, State) ->
%   ?LOG({r, cs, Index, Offset, Length}),
    #state{
        chunkset=ChunkSetPrototype,
        lefted_pieces=LeftedPieceSet,
        lefted_chunks=LeftedChunkArr,
        valid_pieces=ValidPieceSet,
        valid_chunks=ValidChunkArr
    } = State,

    ChunkList = [{Index, Offset, Length}],

    {NewLeftedPieceSet, NewLeftedChunkArr} = delete_chunks(
            ChunkList, LeftedPieceSet, LeftedChunkArr),
    {NewValidPieceSet, NewValidChunkArr} = insert_chunks(
            ChunkList, ValidPieceSet, ValidChunkArr, ChunkSetPrototype),

    NewState = State#state{
        lefted_pieces=NewLeftedPieceSet,
        lefted_chunks=NewLeftedChunkArr,
        valid_pieces=NewValidPieceSet,
        valid_chunks=NewValidChunkArr
    },
    {noreply, NewState};

handle_info({chunk, {dropped,Index,Offset,Length,_PeerPid}}, State) ->
    %% Add dropped parts back to the query
    ?LOG({r, cd, Index, Offset, Length}),
    #state{
        chunkset=ChunkSetPrototype,
        wanted_pieces=PieceSet,
        wanted_chunks=ChunkArr} = State,

    NewPieceSet = etorrent_pieceset:insert(Index, PieceSet),
    Chunks = case etorrent_pieceset:is_member(Index, PieceSet) of
            false -> ChunkSetPrototype;
            true -> array:get(Index, ChunkArr)
        end,
    NewChunkSet = etorrent_chunkset:insert(Offset, Length, Chunks),
    NewChunkArr = array:set(Index, NewChunkSet, ChunkArr),

    NewState = State#state{
        wanted_pieces=NewPieceSet,
        wanted_chunks=NewChunkArr},
    {noreply, NewState};

handle_info({chunk, {assigned,Index,Offset,Length,_PeerPid}}, State) ->
%   ?LOG({r, ca, Index, Offset, Length}),
    {noreply, State};

handle_info(check_completed, State) ->
    #state{
        lefted_pieces=PieceSet,
        lefted_chunks=ChunkArr,
        monitored_chunks=Monitored} = State,
    io:write({r, cc, Monitored}),

    NewMonitored = check_completed(Monitored, PieceSet, ChunkArr),

    NewState = State#state{
        monitored_chunks=NewMonitored},
    {noreply, NewState}.


%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% Inserts Chunks into PieceSet and ChunkArr.
-spec insert_chunks([chunk()], pieceset(), array(), chunkset()) -> 
        {pieceset(), array()}.

insert_chunks([H|T] = _Chunks, PieceSet, ChunkArr, ChunkSetPrototype) ->
    {Index, Offset, Length} = H,
    Chunks = case etorrent_pieceset:is_member(Index, PieceSet) of
            false -> ChunkSetPrototype;
            true -> array:get(Index, ChunkArr)
        end,
    NewChunks = etorrent_chunkset:insert(Offset, Length, Chunks),
    NewChunkArr = array:set(Index, NewChunks, ChunkArr),
    NewPieceSet = etorrent_pieceset:insert(Index, PieceSet),
    insert_chunks(T, NewPieceSet, NewChunkArr, ChunkSetPrototype);

insert_chunks([], PieceSet, ChunkArr, _) ->
    {PieceSet, ChunkArr}.


-spec delete_chunks([chunk()], pieceset(), array()) -> 
        {pieceset(), array()}.

delete_chunks([H|T] = _ChunkList, PieceSet, ChunkArr) ->
    {Index, Offset, Length} = H,
    case array:get(Index, ChunkArr) of
    %% Don't care
    undefined ->
        delete_chunks(T, PieceSet, ChunkArr);
    ChunkSet ->
        NewChunkSet = etorrent_chunkset:delete(Offset, Length, ChunkSet),
        {NewPieceSet, NewChunkArr} = 
            case etorrent_chunkset:is_empty(NewChunkSet) of
            %% The piece has no lefted chunks.
            true ->
                NewPieceSetI = etorrent_pieceset:delete(
                    Index, PieceSet),
                NewChunkArrI = array:reset(Index, ChunkArr),
                {NewPieceSetI, NewChunkArrI};
            false ->
                NewChunkArrI = array:set(Index, NewChunkSet, ChunkArr),
                {PieceSet, NewChunkArrI}
            end,
        delete_chunks(T, NewPieceSet, NewChunkArr)
    end;

delete_chunks([], PieceSet, ChunkArr) -> {PieceSet, ChunkArr}.


retrieve_chunks(NumChunks, Valid, ChunkArr, Acc) when NumChunks>0 ->
    
    case min_piece(Valid) of
        %% no pieces left
        false -> {Valid, ChunkArr, Acc};
        Index ->
            ChunkSet = array:get(Index, ChunkArr),
            case etorrent_chunkset:extract(ChunkSet, NumChunks) of
                %% Numchunks of pieces were extracted. 
                %% Set lefted chunks back.
                {Offsets, NewChunkSet, 0} ->
                    NewChunkArr = array:set(Index, NewChunkSet, ChunkArr),
                    NewAcc = add_offsets(Index, Offsets, Acc),
                    {Valid, NewChunkArr, NewAcc};

                {Offsets, _EmptyChunkSet, NewNumChunks} ->
                    NewChunkArr = array:reset(Index, ChunkArr),
                    NewValid = etorrent_pieceset:delete(Index, Valid),
                    NewAcc = add_offsets(Index, Offsets, Acc),
                    retrieve_chunks(NewNumChunks, NewValid, NewChunkArr, NewAcc)
            end
    end.


add_offsets(Index, [{Offset, Length}|T], Acc) ->
    add_offsets(Index, T, [{Index, Offset, Length}|Acc]);

add_offsets(_Index, [], Acc) -> Acc.

    
min_piece(Set) ->
    try etorrent_pieceset:min(Set)
    catch error:badarg -> false
    end.


check_completed(ChunkList, PieceSet, ChunkArr) ->
    check_completed(ChunkList, PieceSet, ChunkArr, []).


check_completed([H|T], PieceSet, ChunkArr, Acc) ->
    #wish{
        pid = Pid,
        ref = Ref,
        chunks = ChunkList
    } = H,
    NewAcc = case intersection(ChunkList, PieceSet, ChunkArr) of
        [] -> inform_client(Pid, Ref), Acc;
        NewChunkList -> [H#wish{chunks=NewChunkList}|Acc]
    end,
    check_completed(T, PieceSet, ChunkArr, NewAcc);

check_completed([], _PieceSet, _ChunkArr, Acc) -> Acc.


%% @doc Delete elements from `Chunks' which are not listed in 
%%      `PieceSet' and `ChunkArr'.
intersection(Chunks, PieceSet, ChunkArr) ->
    lists:filter(fun(X) -> in(X, PieceSet, ChunkArr) end, Chunks).

difference(Chunks, PieceSet, ChunkArr) ->
    lists:filter(fun(X) -> not in(X, PieceSet, ChunkArr) end, Chunks).


in({Index, Offset, Length}, PieceSet, ChunkArr) ->
    etorrent_pieceset:is_member(Index, PieceSet) andalso
        begin
            ChunkSet = array:get(Index, ChunkArr),
            etorrent_chunkset:in(Offset, Length, ChunkSet)
        end.


inform_client(Pid, Ref) ->
    Pid ! {completed, Ref}.

-ifdef(TEST).

-endif.
