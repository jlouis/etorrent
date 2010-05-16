%%%-------------------------------------------------------------------
%%% File    : etorrent_torrent.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Library for manipulating the torrent table.
%%%
%%% Created : 15 Jun 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_torrent).

-behaviour(gen_server).

-include("etorrent_torrent.hrl").

%% Counter for how many pieces is missing from this torrent
-record(c_pieces, {id :: non_neg_integer(), % Torrent id
                   missing :: non_neg_integer()}). % Number of missing pieces
%% API
-export([start_link/0,
         new/3, all/0, statechange/2,
         num_pieces/1, decrease_not_fetched/1,
         is_seeding/1, seeding/0,
         state/1,
         find/1, is_endgame/1, mode/1]).

-export([init/1, handle_call/3, handle_cast/2, code_change/3,
         handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-record(state, { monitoring }).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% Function: new(Id, LoadData, NPieces) -> NPieces
%% Description: Initialize a torrent entry for Id with the tracker
%%   state as given. Pieces is the number of pieces for this torrent.
%% Precondition: The #piece table has been filled with the torrents pieces.
%%--------------------------------------------------------------------
new(Id, Info, NPieces) ->
    gen_server:call(?SERVER, {new, Id, Info, NPieces}).

%%--------------------------------------------------------------------
%% Function: mode(Id) -> seeding | endgame | leeching
%% Description: Return the current mode of the torrent.
%%--------------------------------------------------------------------
mode(Id) ->
    gen_server:call(?SERVER, {mode, Id}).

%%--------------------------------------------------------------------
%% Function: all() -> Rows
%% Description: Return all torrents, sorted by Id
%%--------------------------------------------------------------------
all() ->
    gen_server:call(?SERVER, all).

statechange(Id, What) ->
    gen_server:call(?SERVER, {statechange, Id, What}).

%%--------------------------------------------------------------------
%% Function: num_pieces(Id) -> {value, integer()}
%% Description: Return the number of pieces for torrent Id
%%--------------------------------------------------------------------
num_pieces(Id) ->
    gen_server:call(?SERVER, {num_pieces, Id}).

state(Id) ->
    case ets:lookup(etorrent_torrent, Id) of
        [] -> not_found;
        [M] -> {value, M#torrent.state}
    end.

%% Returns {value, True} if the torrent is a seeding torrent
is_seeding(Id) ->
    {value, S} = state(Id),
    S =:= seeding.

%% Returns all torrents which are currently seeding
seeding() ->
    Torrents = all(),
    {value, [T#torrent.id || T <- Torrents,
                    T#torrent.state =:= seeding]}.

%% Request the torrent information.
find(Id) ->
    [T] = ets:lookup(etorrent_torrent, Id),
    {torrent_info, T#torrent.uploaded, T#torrent.downloaded, T#torrent.left}.


%%--------------------------------------------------------------------
%% Function: decrease_not_fetched(Id) -> ok | endgame
%% Description: track that we downloaded a piece, eventually updating
%%  the endgame result.
%%--------------------------------------------------------------------
decrease_not_fetched(Id) ->
    gen_server:call(?SERVER, {decrease, Id}).


%%--------------------------------------------------------------------
%% Function: is_endgame(Id) -> bool()
%% Description: Returns true if the torrent is in endgame mode
%%--------------------------------------------------------------------
is_endgame(Id) ->
    case ets:lookup(etorrent_torrent, Id) of
        [T] -> T#torrent.state =:= endgame;
        [] -> false % The torrent isn't there anymore.
    end.

init([]) ->
    _ = ets:new(etorrent_torrent, [protected, named_table,
                                   {keypos, 2}]),
    _ = ets:new(etorrent_c_pieces, [protected, named_table,
                                    {keypos, 2}]),
    {ok, #state{ monitoring = dict:new() }}.

handle_call({new, Id, {{uploaded, U}, {downloaded, D},
                       {left, L}, {total, T}}, NPieces}, {Pid, _Tag}, S) ->
    State = case L of
                0 -> etorrent_event_mgr:seeding_torrent(Id),
                     seeding;
                _ -> leeching
            end,
    true = ets:insert_new(etorrent_torrent,
                #torrent { id = Id,
                           left = L,
                           total = T,
                           uploaded = U,
                           downloaded = D,
                           pieces = NPieces,
                           state = State }),
    Missing = etorrent_piece_mgr:num_not_fetched(Id),
    true = ets:insert_new(etorrent_c_pieces, #c_pieces{ id = Id, missing = Missing}),
    R = erlang:monitor(process, Pid),
    NS = S#state { monitoring = dict:store(R, Id, S#state.monitoring) },
    {reply, ok, NS};
handle_call({mode, Id}, _F, S) ->
    [#torrent { state = St}] = ets:lookup(etorrent_torrent, Id),
    {reply, St, S};
handle_call(all, _F, S) ->
    Q = all(#torrent.id),
    {reply, Q, S};
handle_call({num_pieces, Id}, _F, S) ->
    [R] = ets:lookup(etorrent_torrent, Id),
    {reply, {value, R#torrent.pieces}, S};
handle_call({statechange, Id, What}, _F, S) ->
    Q = state_change(Id, What),
    {reply, Q, S};
handle_call({decrease, Id}, _F, S) ->
    N = ets:update_counter(etorrent_c_pieces, Id, {#c_pieces.missing, -1}),
    case N of
        0 ->
            state_change(Id, endgame),
            {reply, endgame, S};
        N when is_integer(N) ->
            {reply, ok, S}
    end;
handle_call(_M, _F, S) ->
    {noreply, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({'DOWN', Ref, _, _, _}, S) ->
    {ok, Id} = dict:find(Ref, S#state.monitoring),
    ets:delete(etorrent_torrent, Id),
    ets:delete(etorrent_c_pieces, Id),
    {noreply, S#state { monitoring = dict:erase(Ref, S#state.monitoring) }};
handle_info(_M, S) ->
    {noreply, S}.

code_change(_OldVsn, S, _Extra) ->
    {ok, S}.

terminate(_Reason, _S) ->
    ok.

%%--------------------------------------------------------------------
%% Function: all(Pos) -> Rows
%% Description: Return all torrents, sorted by Pos
%%--------------------------------------------------------------------
all(Pos) ->
    Objects = ets:match_object(etorrent_torrent, '$1'),
    lists:keysort(Pos, Objects).

%% Change the state of the torrent with Id, altering it by the "What" part.
%% Precondition: Torrent exists in the ETS table.
state_change(_Id, []) ->
    ok;
state_change(Id, [What | Rest]) ->
    [T] = ets:lookup(etorrent_torrent, Id),
    New = case What of
              unknown ->
                  T#torrent{state = unknown};
              leeching ->
                  T#torrent{state = leeching};
              seeding ->
                  T#torrent{state = seeding};
              endgame ->
                  T#torrent{state = endgame};
              {add_downloaded, Amount} ->
                  T#torrent{downloaded = T#torrent.downloaded + Amount};
              {add_upload, Amount} ->
                  T#torrent{uploaded = T#torrent.uploaded + Amount};
              {subtract_left, Amount} ->
                  Left = T#torrent.left - Amount,
                  case Left of
                      0 ->
                          T#torrent { left = 0, state = seeding };
                      N when N =< T#torrent.total ->
                          T#torrent { left = N }
                  end;
              {tracker_report, Seeders, Leechers} ->
                  T#torrent{seeders = Seeders, leechers = Leechers}
          end,
    ets:insert(etorrent_torrent, New),
    case {T#torrent.state, New#torrent.state} of
        {leeching, seeding} ->
            etorrent_event_mgr:seeding_torrent(Id),
            ok;
        _ ->
            ok
    end,
    state_change(Id, Rest);
state_change(Id, What) when is_integer(Id) ->
    state_change(Id, [What]).
