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
         chunked_pieces/1, size_piece/1,
	 piece_info/2, find_new/2, fetched/2, bitfield/1, piecehashes/1,
	 get_operations/2, valid/2, interesting/2,
	 chunkify_piece/2, select/1,
         add_monitor/2, num_not_fetched/1, check_interest/2, add_pieces/2, chunk/3]).

-export([increase_count/2, decrease_count/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% Individual pieces are represented via the piece record
-record(piece, {idpn, % {Id, PieceNumber} pair identifying the piece
                hash, % Hash of piece
                id, % (IDX) Id of this piece owning this piece, again for an index
                piece_number, % Piece Number of piece, replicated for fast qlc access
                files, % File operations to manipulate piece
                left = unknown, % Number of chunks left...
		count = 0, % How many peers has this piece
                state}). % (IDX) state is: fetched | not_fetched | chunked

-type piece() :: #piece{}.
-export_type([piece/0]).

-record(state, { monitoring }).

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

%% @doc What is the size of a given piece
size_piece(#piece{state = fetched}) -> 0;
size_piece(#piece{state = not_fetched, files = Files}) ->
    lists:sum([Sz || {_F, _O, Sz} <- Files]).


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

increase_count(Id, PN) ->
    alter_count(Id, PN, 1).

decrease_count(Id, PN) ->
    alter_count(Id, PN, -1).

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
                  R <- ets:table(?TAB),
                  R#piece.id =:= Id,
                  R#piece.state =:= not_fetched]),
    length(qlc:e(Q)).

%%--------------------------------------------------------------------
%% Function: check_interest(Id, PieceSet) -> interested | not_interested | invalid_piece
%% Description: Given a set of pieces, return if we are interested in any of them.
%%--------------------------------------------------------------------
check_interest(Id, PieceSet) when is_integer(Id) ->
    It = gb_sets:iterator(PieceSet),
    find_interest_piece(Id, gb_sets:next(It), []).

%%--------------------------------------------------------------------
%% Function: select(Id) -> [#piece]
%% Description: Return all pieces for a torrent id
%%--------------------------------------------------------------------
select(Id) ->
    MatchHead = #piece { idpn = {Id, '_'}, _ = '_'},
    ets:select(?TAB, [{MatchHead, [], ['$_']}]).

piecehashes(Id) ->
    Pieces = select(Id),
    [{PN, Hash} || #piece { idpn = {_, PN}, hash = Hash} <- Pieces].

piece_info(Id, PN) ->
    case ets:lookup(?TAB, {Id, PN}) of
	[#piece { hash = H, files = Ops }] ->
	    {H, Ops}
    end.

%%--------------------------------------------------------------------
%% Function: get_operations(Id, PieceNumber) -> {ok, [operation()]}, none
%% Description: Return the piece PieceNumber for the Id torrent
%%--------------------------------------------------------------------
get_operations(Id, Pn) ->
    case ets:lookup(?TAB, {Id, Pn}) of
	[] ->
	    none;
	[P] -> {ok, P#piece.files}
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
    find_new_1(Id, gb_sets:next(Iter)).

find_new_1(_Id, none) -> none;
find_new_1(Id, {PN, Nxt}) ->
    case ets:lookup(?TAB, {Id, PN}) of
        [] ->
            find_new_1(Id, gb_sets:next(Nxt));
        [#piece{ state = not_fetched } = P] -> {P, PN};
        [_P] -> find_new_1(Id, gb_sets:next(Nxt))
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
      fun({PN, Hash, Files, State}) ->
              ets:insert(?TAB,
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
find_interest_piece(_Id, none, []) ->
    not_interested;
find_interest_piece(_Id, none, Acc) ->
    {interested, Acc};
find_interest_piece(Id, {Pn, Next}, Acc) ->
    case ets:lookup(?TAB, {Id, Pn}) of
        [] ->
            invalid_piece;
        [#piece{ state = State}] ->
            case State of
                fetched ->
                    find_interest_piece(Id, gb_sets:next(Next), Acc);
                _Other ->
                    find_interest_piece(Id, gb_sets:next(Next), [Pn | Acc])
            end
    end.

chunkify_piece(Id, #piece{ files = Files, state = State, idpn = IDPN }) ->
    Chunks = chunkify(Files),
    NumChunks = length(Chunks),
    not_fetched = State,
    {Id, Idx} = IDPN,
    ok = etorrent_piece_mgr:chunk(Id, Idx, NumChunks),
    {Id, Idx, Chunks}.

%% @doc Break a piece into logical chunks
%%
%%   From a list of operations to read/write a piece, construct
%%   a list of chunks given by Offset of the chunk, Size of the chunk and
%%   how to read/write that chunk.
%% @end
-spec chunkify([operation()]) -> [{integer(), integer(), [operation()]}].
%% First, we call the version of the function doing the grunt work.
chunkify(Operations) ->
    chunkify(0, 0, [], Operations, ?DEFAULT_CHUNK_SIZE).

%% Suppose the next File operation on the piece has 0 bytes in size, then it
%%  is exhausted and must be thrown away.
chunkify(AtOffset, EatenBytes, Operations,
         [{_Path, _Offset, 0} | Rest], Left) ->
    chunkify(AtOffset, EatenBytes, Operations, Rest, Left);

%% There are no more file operations to carry out. Hence we reached the end of
%%   the piece and we just return the last chunk operation. Remember to reverse
%%   the list of operations for that chunk as we build it in reverse.
chunkify(AtOffset, EatenBytes, Operations, [], _Sz) ->
    [{AtOffset, EatenBytes, lists:reverse(Operations)}];

%% There are no more bytes left to add to this chunk. Recurse by calling
%%   on the rest of the problem and add our chunk to the front when coming
%%   back. Remember to reverse the Operations list built in reverse.
chunkify(AtOffset, EatenBytes, Operations, OpsLeft, 0) ->
    R = chunkify(AtOffset + EatenBytes, 0, [], OpsLeft, ?DEFAULT_CHUNK_SIZE),
    [{AtOffset, EatenBytes, lists:reverse(Operations)} | R];

%% The next file we are processing have a larger size than what is left for this
%%   chunk. Hence we can just eat off that many bytes from the front file.
chunkify(AtOffset, EatenBytes, Operations,
         [{Path, Offset, Size} | Rest], Left) when Left =< Size ->
    chunkify(AtOffset, EatenBytes + Left,
             [{Path, Offset, Left} | Operations],
             [{Path, Offset+Left, Size - Left} | Rest],
             0);

%% The next file does *not* have enough bytes left, so we eat all the bytes
%%   we can get from it, and move on to the next file.
chunkify(AtOffset, EatenBytes, Operations,
        [{Path, Offset, Size} | Rest], Left) when Left > Size ->
    chunkify(AtOffset, EatenBytes + Size,
             [{Path, Offset, Size} | Operations],
             Rest,
             Left - Size).

alter_count(I, PN, C) ->
    R = ets:update_counter(?TAB, {I, PN}, {#piece.count, C}),
    true = R =< 0,
    ok.
