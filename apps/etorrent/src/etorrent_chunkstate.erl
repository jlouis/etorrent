-module(etorrent_chunkstate).
%% This module implements the client interface to processes
%% assigning and tracking the state of chunk requests.
%%
%% This interface is implemented by etorrent_progress, etorrent_pending
%% and etorrent_endgame. Each process type handles a subset of these
%% operations. This module is intended to be used internally by the
%% torrent local services. A wrapper is provided by the etorrent_download
%% module.

-export([request/3,
         requests/1,
         assigned/5,
         assigned/3,
         dropped/5,
         dropped/3,
         dropped/2,
         fetched/5,
         stored/5,
         forward/1]).


%% @doc
%% @end
request(Numchunks, Peerset, Srvpid) ->
    Call = {chunk, {request, Numchunks, Peerset, self()}},
    gen_server:call(Srvpid, Call).

%% @doc Return a list of requests held by a process.
%% @end
-spec requests(pid()) -> [{pid, {integer(), integer(), integer()}}].
requests(SrvPid) ->
    gen_server:call(SrvPid, {chunk, requests}).


%% @doc
%% @end
-spec assigned(non_neg_integer(), non_neg_integer(),
               non_neg_integer(), pid(), pid()) -> ok.
assigned(Piece, Offset, Length, Peerpid, Srvpid) ->
    Srvpid ! {chunk, {assigned, Piece, Offset, Length, Peerpid}},
    ok.


%% @doc
%% @end
-spec assigned([{non_neg_integer(), non_neg_integer(),
                 non_neg_integer()}], pid(), pid()) -> ok.
assigned(Chunks, Peerpid, Srvpid) ->
    [assigned(P, O, L, Peerpid, Srvpid) || {P, O, L} <- Chunks],
    ok.


%% @doc
%% @end
-spec dropped(non_neg_integer(), non_neg_integer(),
              non_neg_integer(), pid(), pid()) -> ok.
dropped(Piece, Offset, Length, Peerpid, Srvpid) ->
    Srvpid ! {chunk, {dropped, Piece, Offset, Length, Peerpid}},
    ok.


%% @doc
%% @end
-spec dropped([{non_neg_integer(), non_neg_integer(),
                non_neg_integer()}], pid(), pid()) -> ok.
dropped(Chunks, Peerpid, Srvpid) ->
    [dropped(P, O, L, Peerpid, Srvpid) || {P, O, L} <- Chunks],
    ok.


%% @doc
%% @end
-spec dropped(pid(), pid()) -> ok.
dropped(Peerpid, Srvpid) ->
    Srvpid ! {chunk, {dropped, Peerpid}},
    ok.



%% @doc
%% @end
-spec fetched(non_neg_integer(), non_neg_integer(),
                   non_neg_integer(), pid(), pid()) -> ok.
fetched(Piece, Offset, Length, Peerpid, Srvpid) ->
    Srvpid ! {chunk, {fetched, Piece, Offset, Length, Peerpid}},
    ok.


%% @doc
%% @end
-spec stored(non_neg_integer(), non_neg_integer(),
             non_neg_integer(), pid(), pid()) -> ok.
stored(Piece, Offset, Length, Peerpid, Srvpid) ->
    Srvpid ! {chunk, {stored, Piece, Offset, Length, Peerpid}},
    ok.


%% @doc
%% @end
-spec forward(pid()) -> ok.
forward(Pid) ->
    Tailref = self() ! make_ref(),
    forward_(Pid, Tailref).

forward_(Pid, Tailref) ->
    receive
        Tailref -> ok;
        {chunk, _}=Msg ->
            Pid ! Msg,
            forward_(Pid, Tailref)
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(chunkstate, ?MODULE).

pop() -> etorrent_utils:first().
make_pid() -> spawn(fun erlang:now/0).

request_test() ->
    Peer = self(),
    Set  = make_ref(),
    Num  = make_ref(),
    Srv = spawn_link(fun() ->
        etorrent_utils:reply(fun({chunk, {request, Num, Set, Peer}}) -> ok end)
    end),
    ?assertEqual(ok, ?chunkstate:request(Num, Set, Srv)).

requests_test() ->
    Ref = make_ref(),
    Srv = spawn_link(fun() ->
        etorrent_utils:reply(fun({chunk, requests}) -> Ref end)
    end),
    ?assertEqual(Ref, ?chunkstate:requests(Srv)).

assigned_test() ->
    Pid = make_pid(),
    ok = ?chunkstate:assigned(1, 2, 3, Pid, self()),
    ?assertEqual({chunk, {assigned, 1, 2, 3, Pid}}, pop()).

assigned_list_test() ->
    Pid = make_pid(),
    Chunks = [{1, 2, 3}, {4, 5, 6}],
    ok = ?chunkstate:assigned(Chunks, Pid, self()),
    ?assertEqual({chunk, {assigned, 1, 2, 3, Pid}}, pop()),
    ?assertEqual({chunk, {assigned, 4, 5, 6, Pid}}, pop()).

dropped_test() ->
    Pid = make_pid(),
    ok = ?chunkstate:dropped(1, 2, 3, Pid, self()),
    ?assertEqual({chunk, {dropped, 1, 2, 3, Pid}}, pop()).

dropped_list_test() ->
    Pid = make_pid(),
    Chunks = [{1, 2, 3}, {4, 5, 6}],
    ok = ?chunkstate:dropped(Chunks, Pid, self()),
    ?assertEqual({chunk, {dropped, 1, 2, 3, Pid}}, pop()),
    ?assertEqual({chunk, {dropped, 4, 5, 6, Pid}}, pop()).

dropped_all_test() ->
    Pid = make_pid(),
    ok = ?chunkstate:dropped(Pid, self()),
    ?assertEqual({chunk, {dropped, Pid}}, pop()).

fetched_test() ->
    Pid = make_pid(),
    ok = ?chunkstate:fetched(1, 2, 3, Pid, self()),
    ?assertEqual({chunk, {fetched, 1, 2, 3, Pid}}, pop()).

stored_test() ->
    Pid = make_pid(),
    ok = ?chunkstate:stored(1, 2, 3, Pid, self()),
    ?assertEqual({chunk, {stored, 1, 2, 3, Pid}}, pop()).

forward_test() ->
    Main = self(),
    Pid = make_pid(),
    {Slave, Ref} = erlang:spawn_monitor(fun() ->
        etorrent_utils:expect(go),
        ?chunkstate:forward(Main),
        etorrent_utils:expect(die)
    end),
    ok = ?chunkstate:assigned(1, 2, 3, Pid, Slave),
    ok = ?chunkstate:assigned(4, 5, 6, Pid, Slave),
    Slave ! go,
    ?assertEqual({chunk, {assigned, 1, 2, 3, Pid}}, pop()),
    ?assertEqual({chunk, {assigned, 4, 5, 6, Pid}}, pop()),
    Slave ! die,
    etorrent_utils:wait(Ref).

-endif.
