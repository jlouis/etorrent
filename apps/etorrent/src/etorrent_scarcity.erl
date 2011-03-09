-module(etorrent_scarcity).
-behaviour(gen_server).
%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc A set of pieces ordered by scarcity
%%
%% This module implements a piece set that is ordered by the number of peers
%% that provide a valid copy of the piece. This is implemented by inserting
%% {NumPeers, PieceIndex} pairs into an ordered set.
%%
%% An array mapping piece indexes to the number of peers providing the piece
%% is also maintained to ensure that we don't need to scan through the set
%% for each update.
%% @end


%% gproc entries
-export([register_scarcity_server/1,
         lookup_scarcity_server/1,
         await_scarcity_server/1]).

%% api functions
-export([start_link/2,
         add_peer/1,
         add_piece/2,
         get_order/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).


-type torrent_id() :: etorrent_types:torrent_id().
-type pieceset() :: etorrent_pieceset:pieceset().
-type monitorset() :: etorrent_monitorset:monitorset().

-record(state, {
    torrent_id :: torrent_id(),
    num_pieces :: pos_integer(),
    num_peers  :: array(),
    peer_monitors :: monitorset()}).


%% @doc
%% @end
-spec register_scarcity_server(torrent_id()) -> true.
register_scarcity_server(TorrentID) ->
    gproc:add_local_name({etorrent, TorrentID, scarcity}).


%% @doc
%% @end
-spec lookup_scarcity_server(torrent_id()) -> pid().
lookup_scarcity_server(TorrentID) ->
    gproc:lookup_local_name({etorrent, TorrentID, scarcity}).


%% @doc
%% @end
-spec await_scarcity_server(torrent_id()) -> pid().
await_scarcity_server(TorrentID) ->
    Name = {etorrent, TorrentID, scarcity},
    {Pid, undefined} = gproc:await({n, l, Name}, 5000),
    Pid.


%% @doc
%% @end
-spec start_link(torrent_id(), pos_integer()) -> {ok, pid()}.
start_link(TorrentID, NumPieces) ->
    gen_server:start_link(?MODULE, [TorrentID, NumPieces], []).


%% @doc
%% @end
-spec add_peer(torrent_id()) -> {ok, pieceset()}.
add_peer(TorrentID) ->
    SrvPid = lookup_scarcity_server(TorrentID),
    gen_server:call(SrvPid, {add_peer, self()}).


%% @doc
%% @end
-spec add_piece(torrent_id(), pos_integer()) -> {ok, pieceset()}.
add_piece(TorrentID, PieceIndex) ->
    SrvPid = lookup_scarcity_server(TorrentID),
    gen_server:call(SrvPid, {add_piece, self(), PieceIndex}).

%% @doc
%% @end
-spec get_order(torrent_id(), pieceset()) -> {ok, [pos_integer()]}.
get_order(TorrentID, Pieceset) ->
    SrvPid = lookup_scarcity_server(TorrentID),
    gen_server:call(SrvPid, {get_order, Pieceset}).


%% @private
init([TorrentID, NumPieces]) ->
    register_scarcity_server(TorrentID),
    InitState = #state{
        torrent_id=TorrentID,
        num_pieces=NumPieces,
        num_peers=array:new([{default, 0}]),
        peer_monitors=etorrent_monitorset:new()},
    {ok, InitState}.


%% @private
handle_call({add_peer, PeerPid}, _, State) ->
    #state{num_pieces=NumPieces, peer_monitors=Monitors} = State,
    Pieceset = etorrent_pieceset:new(NumPieces),
    NewMonitors = etorrent_monitorset:insert(PeerPid, Pieceset, Monitors),
    NewState = State#state{peer_monitors=NewMonitors},
    {reply, {ok, Pieceset}, NewState};

handle_call({add_piece, Pid, PieceIndex}, _, State) ->
    #state{peer_monitors=Monitors, num_peers=Numpeers} = State,
    Prev = array:get(PieceIndex, Numpeers),
    NewNumpeers = array:set(PieceIndex, Prev + 1, Numpeers),
    Pieceset = etorrent_monitorset:fetch(Pid, Monitors),
    NewPieceset = etorrent_pieceset:insert(PieceIndex, Pieceset),
    NewMonitors = etorrent_monitorset:update(Pid, NewPieceset, Monitors),
    NewState = State#state{
        peer_monitors=NewMonitors,
        num_peers=NewNumpeers},
    {reply, {ok, NewPieceset}, NewState};

handle_call({get_order, Pieceset}, _, State) ->
    #state{num_peers=Numpeers} = State,
    Piecelist = lists:sort(fun(A, B) ->
        array:get(A, Numpeers) =< array:get(B, Numpeers)
    end, etorrent_pieceset:to_list(Pieceset)),
    {reply, {ok, Piecelist}, State}.


%% @private
handle_cast(_, State) ->
    {noreply, State}.

%% @private
handle_info({'DOWN', _, process, Pid, _}, State) ->
    #state{peer_monitors=Monitors, num_peers=Numpeers} = State,
    %% Decrement the counter for each piece that this peer provided.
    Pieceset = etorrent_monitorset:fetch(Pid, Monitors),
    Piecelist = etorrent_pieceset:to_list(Pieceset),
    NewNumpeers = lists:foldl(fun(Index, Acc) ->
        PrevCount = array:get(Index, Acc),
        array:set(Index, PrevCount - 1, Acc)
    end, Numpeers, Piecelist),
    NewMonitors = etorrent_monitorset:delete(Pid, Monitors),
    NewState = State#state{
        peer_monitors=NewMonitors,
        num_peers=NewNumpeers},
    {noreply, NewState}.

%% @private
terminate(_, State) ->
    {ok, State}.

%% @private
code_change(_, State, _) ->
    {ok, State}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(scarcity, ?MODULE).
-define(pieceset, etorrent_pieceset).

scarcity_server_test_() ->
    {setup,
        fun()  -> application:start(gproc) end,
        fun(_) -> application:stop(gproc) end,
        [?_test(register_case()),
         ?_test(server_registers_case()),
         ?_test(initial_ordering_case()),
         ?_test(empty_ordering_case()),
         ?_test(init_pieceset_case()),
         ?_test(one_available_case()),
         ?_test(decrement_on_exit_case())]}.

register_case() ->
    true = ?scarcity:register_scarcity_server(0),
    ?assertEqual(self(), ?scarcity:lookup_scarcity_server(0)),
    ?assertEqual(self(), ?scarcity:await_scarcity_server(0)).

server_registers_case() ->
    {ok, Pid} = ?scarcity:start_link(1, 1),
    ?assertEqual(Pid, ?scarcity:lookup_scarcity_server(1)).

initial_ordering_case() ->
    {ok, _} = ?scarcity:start_link(2, 8),
    Pieces  = ?pieceset:from_list([0,1,2,3,4,5,6,7], 8),
    {ok, Order} = ?scarcity:get_order(2, Pieces),
    ?assertEqual([0,1,2,3,4,5,6,7], Order).

empty_ordering_case() ->
    {ok, _} = ?scarcity:start_link(3, 8),
    Pieces  = ?pieceset:from_list([], 8),
    {ok, Order} = ?scarcity:get_order(3, Pieces),
    ?assertEqual([], Order).

init_pieceset_case() ->
    {ok, _} = ?scarcity:start_link(4, 8),
    {ok, Set} = ?scarcity:add_peer(4),
    ?assertEqual([], ?pieceset:to_list(Set)).

one_available_case() ->
    {ok, _} = ?scarcity:start_link(5, 8),
    {ok, _} = ?scarcity:add_peer(5),
    {ok, _} = ?scarcity:add_piece(5, 0),
    Pieces  = ?pieceset:from_list([0,1,2,3,4,5,6,7], 8),
    {ok, Order} = ?scarcity:get_order(5, Pieces),
    ?assertEqual([1,2,3,4,5,6,7,0], Order).

decrement_on_exit_case() ->
    {ok, _} = ?scarcity:start_link(6, 8),
    Main = self(),
    Pid = spawn_link(fun() ->
        {ok, _} = ?scarcity:add_peer(6),
        {ok, _} = ?scarcity:add_piece(6, 0),
        {ok, _} = ?scarcity:add_piece(6, 2),
        Main ! done,
        receive die -> ok end
    end),
    receive done -> ok end,
    Pieces  = ?pieceset:from_list([0,1,2,3,4,5,6,7], 8),
    {ok, O1} = ?scarcity:get_order(6, Pieces),
    ?assertEqual([1,3,4,5,6,7,0,2], O1),
    Ref = monitor(process, Pid),
    Pid ! die,
    receive {'DOWN', Ref, _, _, _} -> ok end,
    {ok, O2} = ?scarcity:get_order(6, Pieces),
    ?assertEqual([0,1,2,3,4,5,6,7], O2).

-endif.
