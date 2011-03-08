%%%-------------------------------------------------------------------
%%% File    : etorrent_piece_mgr.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Piece Manager code
%%%
%%% Created : 21 Jul 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------
-module(etorrent_piece_mgr).

-include_lib("stdlib/include/qlc.hrl").
-include("types.hrl").

-behaviour(gen_server).

%% API
-export([start_link/0, decrease_missing_chunks/2, statechange/3,
         chunked_pieces/1,
	 piece_hash/2, find_new/2, fetched/2, bitfield/1, pieces/1,
	 valid/2, interesting/2,
	 chunkify_piece/2, select/1,
         add_monitor/2, num_not_fetched/1, check_interest/2, add_pieces/2, chunk/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% Individual pieces are represented via the piece record
-record(piece, {idpn :: {torrent_id(), integer() | '$1' | '_' },
                hash :: binary() | '_' ,
                left = unknown :: unknown | integer() | '_', % Chunks left
                state :: fetched | not_fetched | chunked | '_' }).

-type piece() :: #piece{}.
-export_type([piece/0]).

-record(state, { monitoring :: dict() }).

-define(SERVER, ?MODULE).
-define(TAB, etorrent_piece_tbl).
-define(CHUNKED_TAB, etorrent_chunked_tbl).
-define(DEFAULT_CHUNK_SIZE, 16384).

-ignore_xref([{'start_link', 0}]).
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
    [R] = ets:lookup(?TAB, {Id, Idx}),
    R#piece.state =:= fetched.

fetched(Id) ->
    MH = #piece { state = fetched, idpn = {Id, '$1'}, _ = '_'},
    ets:select(?TAB,
               [{MH, [], ['$1']}]).

bitfield(Id) when is_integer(Id) ->
    {value, NP} = etorrent_torrent:num_pieces(Id),
    Fetched = fetched(Id),
    Pieceset = etorrent_pieceset:from_list(Fetched, NP),
    etorrent_proto_wire:encode_bitfield(NP, Pieceset).

%% This call adds a monitor on a torrent controller, so its removal gives
%% us a way to remove the pieces associated with that torrent.
add_monitor(Pid, Id) ->
    gen_server:cast(?SERVER, {add_monitor, Pid, Id}).

%%--------------------------------------------------------------------
%% Function: num_not_fetched(Id) -> integer()
%% Description: Return the number of not_fetched pieces for torrent Id.
%%--------------------------------------------------------------------
num_not_fetched(Id) when is_integer(Id) ->
    Q = qlc:q([R || R <- ets:table(?TAB),
		    begin {IdT, _} = R#piece.idpn,
			  IdT == Id
		    end,
		    R#piece.state =:= not_fetched]),
    length(qlc:e(Q)).

%%--------------------------------------------------------------------
%% Function: check_interest(Id, PieceSet) -> interested | not_interested | invalid_piece
%% Description: Given a set of pieces, return if we are interested in any of them.
%%--------------------------------------------------------------------
check_interest(Id, Pieceset) when is_integer(Id) ->
    PieceList = etorrent_pieceset:to_list(Pieceset),
    find_interest_piece(Id, PieceList, []).

%%--------------------------------------------------------------------
%% Function: select(Id) -> [#piece]
%% Description: Return all pieces for a torrent id
%%--------------------------------------------------------------------
select(Id) ->
    MatchHead = #piece { idpn = {Id, '_'}, _ = '_'},
    ets:select(?TAB, [{MatchHead, [], ['$_']}]).

pieces(Id) ->
    [PN || #piece { idpn = {_, PN} } <- select(Id)].

piece_hash(Id, PN) ->
    case ets:lookup(?TAB, {Id, PN}) of
	[#piece { hash = H }] ->
	    H
    end.

%%--------------------------------------------------------------------
%% Function: valid(Id, PieceNumber) -> bool()
%% Description: Is the piece valid for this torrent?
%%--------------------------------------------------------------------
valid(Id, Pn) when is_integer(Id) ->
    case ets:lookup(?TAB, {Id, Pn}) of
        [] -> false;
        [_] -> true
    end.

%%--------------------------------------------------------------------
%% Function: interesting(Id, Pn) -> bool()
%% Description: Is the piece interesting?
%%--------------------------------------------------------------------
interesting(Id, Pn) when is_integer(Id) ->
    [P] = ets:lookup(?TAB, {Id, Pn}),
    P#piece.state =/= fetched.

%% Search an iterator for a not_fetched piece. Return the #piece
%%   record or none.
-spec find_new(integer(), gb_set()) -> none | {#piece{}, pos_integer()}.
find_new(Id, GBSet) ->
    Iter = gb_sets:iterator(GBSet),
    find_new_worker(Id, gb_sets:next(Iter)).

find_new_worker(_Id, none) -> none;
find_new_worker(Id, {PN, Nxt}) ->
    case ets:lookup(?TAB, {Id, PN}) of
        [] ->
            find_new_worker(Id, gb_sets:next(Nxt));
        [#piece{ state = not_fetched } = P] -> {P, PN};
        [_P] -> find_new_worker(Id, gb_sets:next(Nxt))
    end.

%% (@todo: Somewhat expensive, but we start here) Chunked pieces
-spec chunked_pieces(pos_integer()) -> [pos_integer()].
chunked_pieces(Id) ->
    Objects = ets:lookup(?CHUNKED_TAB, Id),
    [I || {_, I} <- Objects].

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
    _Tid = ets:new(?TAB, [set, protected, named_table,
                                        {keypos, #piece.idpn}]),
    ets:new(?CHUNKED_TAB, [bag, protected, named_table,
			   {keypos, 1}]),
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
      fun({PN, Hash, _Files, State}) ->
              ets:insert(?TAB,
                         #piece { idpn = {Id, PN},
                                  hash = Hash,
                                  state = State})
      end,
      Pieces),
    {reply, ok, S};
handle_call({chunk, Id, Idx, N}, _From, S) ->
    [P] = ets:lookup(?TAB, {Id, Idx}),
    ets:insert(?TAB, P#piece { state = chunked, left = N}),
    ets:insert(?CHUNKED_TAB, {Id, Idx}),
    {reply, ok, S};
handle_call({decrease_missing, Id, Idx}, _From, S) ->
    case ets:update_counter(?TAB, {Id, Idx},
                            {#piece.left, -1}) of
        0 -> {reply, full, S};
        N when is_integer(N) -> {reply, ok, S}
    end;
handle_call({statechange, Id, Idx, State}, _From, S) ->
    [P] = ets:lookup(?TAB, {Id, Idx}),
    ets:insert(?TAB, P#piece { state = State }),
    case State of
	chunked -> ignore;
	_ -> ets:delete_object(?CHUNKED_TAB, {Id, Idx})
    end,
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
    ets:select_delete(?TAB, [{MatchHead, [], [true]}]),
    ets:delete(?CHUNKED_TAB, Id),
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
find_interest_piece(_Id, [], []) ->
    not_interested;
find_interest_piece(_Id, [], Acc) ->
    {interested, Acc};
find_interest_piece(Id, [Pn|Next], Acc) ->
    case ets:lookup(?TAB, {Id, Pn}) of
        [] ->
            invalid_piece;
        [#piece{ state = State}] ->
            case State of
                fetched ->
                    find_interest_piece(Id, Next, Acc);
                _Other ->
                    find_interest_piece(Id, Next, [Pn | Acc])
            end
    end.

chunkify_piece(Id, #piece{ state = State, idpn = {Id, PN} }) ->
    {ok, Sz} = etorrent_io:piece_size(Id, PN),
    Chunks = chunkify(Sz),
    NumChunks = length(Chunks),
    not_fetched = State,
    ok = etorrent_piece_mgr:chunk(Id, PN, NumChunks),
    {Id, PN, Chunks}.

%% @doc Break a piece into logical chunks
%%   From a size, break it up into the off/len pairs we need
%% @end
-spec chunkify(integer()) -> [{integer(), integer()}].
chunkify(Sz) when is_integer(Sz) ->
    chunkify(0, Sz).

chunkify(Off, Sz) when Sz =< ?DEFAULT_CHUNK_SIZE ->
    %% Last chunk
    [{Off, Sz}];
chunkify(Off, Sz) ->
    [{Off, ?DEFAULT_CHUNK_SIZE}
     | chunkify(Off + ?DEFAULT_CHUNK_SIZE, Sz - ?DEFAULT_CHUNK_SIZE)].
