%%%-------------------------------------------------------------------
%%% File    : etorrent_piece_mgr.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Piece Manager code
%%%
%%% Created : 21 Jul 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------
-module(etorrent_piece_mgr).

-include_lib("stdlib/include/qlc.hrl").
-include("etorrent_piece.hrl").

-behaviour(gen_server).

%% API
-export([start_link/0, decrease_missing_chunks/2, statechange/3,
         fetched/2, bitfield/1, select/1, select/2, valid/2, interesting/2,
         add_monitor/2, num_not_fetched/1, check_interest/2, add_pieces/2, chunk/3]).

-export([fetched/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, { monitoring }).
-define(SERVER, ?MODULE).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% Function: add_pieces(Id, FPList) -> void()
%% Args:  Id ::= integer() - torrent id
%%        FPList ::= [{Hash, Files, Done}]
%% Description: Add a list of pieces to the database.
%%--------------------------------------------------------------------
add_pieces(Id, Pieces) ->
    gen_server:call(?SERVER, {add_pieces, Id, Pieces}).

chunk(Id, Idx, N) ->
    gen_server:call(?SERVER, {chunk, Id, Idx, N}).

%%--------------------------------------------------------------------
%% Function: t_decrease_missing_chunks/2
%% Args:       Id ::= integer() - torrent id
%%             PieceNum ::= integer() - piece index
%% Description: Decrease missing chunks for the {Id, PieceNum} pair.
%%--------------------------------------------------------------------
decrease_missing_chunks(Id, Idx) ->
    gen_server:call(?SERVER, {decrease_missing, Id, Idx}).

%%--------------------------------------------------------------------
%% Function: statechange(Id, PieceNumber, S) -> ok
%% Description: Update the {Id, PieceNumber} pair to have state S
%%--------------------------------------------------------------------
statechange(Id, PN, State) ->
    gen_server:call(?SERVER, {statechange, Id, PN, State}).

fetched(Id, Idx) ->
    [R] = ets:lookup(etorrent_piece_tbl, {Id, Idx}),
    R#piece.state =:= fetched.

fetched(Id) ->
    MH = #piece { state = fetched, idpn = {Id, '$1'}, _ = '_'},
    ets:select(etorrent_piece_tbl,
               [{MH, [], ['$1']}]).

bitfield(Id) when is_integer(Id) ->
    {value, NP} = etorrent_torrent:num_pieces(Id),
    Fetched = fetched(Id),
    etorrent_proto_wire:encode_bitfield(
      NP,
      gb_sets:from_list(Fetched)).

%% This call adds a monitor on a torrent controller, so its removal gives
%% us a way to remove the pieces associated with that torrent.
add_monitor(Pid, Id) ->
    gen_server:cast(?SERVER, {add_monitor, Pid, Id}).

%%--------------------------------------------------------------------
%% Function: num_not_fetched(Id) -> integer()
%% Description: Return the number of not_fetched pieces for torrent Id.
%%--------------------------------------------------------------------
num_not_fetched(Id) when is_integer(Id) ->
    Q = qlc:q([R#piece.piece_number ||
                  R <- ets:table(etorrent_piece_tbl),
                  R#piece.id =:= Id,
                  R#piece.state =:= not_fetched]),
    length(qlc:e(Q)).

%%--------------------------------------------------------------------
%% Function: check_interest(Id, PieceSet) -> interested | not_interested | invalid_piece
%% Description: Given a set of pieces, return if we are interested in any of them.
%%--------------------------------------------------------------------
check_interest(Id, PieceSet) when is_integer(Id) ->
    It = gb_sets:iterator(PieceSet),
    find_interest_piece(Id, gb_sets:next(It)).

%%--------------------------------------------------------------------
%% Function: select(Id) -> [#piece]
%% Description: Return all pieces for a torrent id
%%--------------------------------------------------------------------
select(Id) ->
    MatchHead = #piece { idpn = {Id, '_'}, _ = '_'},
    ets:select(etorrent_piece_tbl, [{MatchHead, [], ['$_']}]).

%%--------------------------------------------------------------------
%% Function: select(Id, PieceNumber) -> [#piece]
%% Description: Return the piece PieceNumber for the Id torrent
%%--------------------------------------------------------------------
select(Id, PN) ->
    ets:lookup(etorrent_piece_tbl, {Id, PN}).

%%--------------------------------------------------------------------
%% Function: valid(Id, PieceNumber) -> bool()
%% Description: Is the piece valid for this torrent?
%%--------------------------------------------------------------------
valid(Id, Pn) when is_integer(Id) ->
    case ets:lookup(etorrent_piece_tbl, {Id, Pn}) of
        [] -> false;
        [_] -> true
    end.

%%--------------------------------------------------------------------
%% Function: interesting(Id, Pn) -> bool()
%% Description: Is the piece interesting?
%%--------------------------------------------------------------------
interesting(Id, Pn) when is_integer(Id) ->
    [P] = ets:lookup(etorrent_piece_tbl, {Id, Pn}),
    case P#piece.state of
        fetched ->
            false;
        _ ->
            true
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([]) ->
    _Tid = ets:new(etorrent_piece_tbl, [set, protected, named_table,
                                        {keypos, #piece.idpn}]),
    {ok, #state{ monitoring = dict:new()}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({add_pieces, Id, Pieces}, _From, S) ->
    lists:foreach(
      fun({PN, Hash, Files, State}) ->
              ets:insert(etorrent_piece_tbl,
                         #piece { idpn = {Id, PN},
                                  id = Id,
                                  piece_number = PN,
                                  hash = Hash,
                                  files = Files,
                                  state = State})
      end,
      Pieces),
    {reply, ok, S};
handle_call({chunk, Id, Idx, N}, _From, S) ->
    [P] = ets:lookup(etorrent_piece_tbl, {Id, Idx}),
    ets:insert(etorrent_piece_tbl, P#piece { state = chunked, left = N}),
    {reply, ok, S};
handle_call({decrease_missing, Id, Idx}, _From, S) ->
    case ets:update_counter(etorrent_piece_tbl, {Id, Idx},
                            {#piece.left, -1}) of
        0 -> {reply, full, S};
        N when is_integer(N) -> {reply, ok, S}
    end;
handle_call({statechange, Id, Idx, State}, _From, S) ->
    [P] = ets:lookup(etorrent_piece_tbl, {Id, Idx}),
    ets:insert(etorrent_piece_tbl, P#piece { state = State }),
    {reply, ok, S};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({add_monitor, Pid, Id}, S) ->
    R = erlang:monitor(process, Pid),
    {noreply, S#state { monitoring = dict:store(R, Id, S#state.monitoring)}};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({'DOWN', Ref, _, _, _}, S) ->
    {ok, Id} = dict:find(Ref, S#state.monitoring),
    MatchHead = #piece { idpn = {Id, '_'}, _ = '_'},
    ets:select_delete(etorrent_piece_tbl, [{MatchHead, [], [true]}]),
    {noreply, S#state { monitoring = dict:erase(Ref, S#state.monitoring)}};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
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
find_interest_piece(_Id, none) ->
    not_interested;
find_interest_piece(Id, {Pn, Next}) ->
    case ets:lookup(etorrent_piece_tbl, {Id, Pn}) of
        [] ->
            invalid_piece;
        [P] when is_record(P, piece) ->
            case P#piece.state of
                fetched ->
                    find_interest_piece(Id, gb_sets:next(Next));
                _Other ->
                    interested
            end
    end.
