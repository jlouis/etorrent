%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Torrent Control process
%% <p>This process controls a (single) Torrent Download. It is the
%% "first" process started and it checks the torrent for
%% correctness. When it has checked the torrent, it will start up the
%% rest of the needed processes, attach them to the supervisor and
%% then lay dormant for most of the time, until the torrent needs to
%% be stopped again.</p>
%% <p><b>Note:</b> This module is pretty old,
%% and is a prime candidate for some rewriting.</p>
%% @end
-module(etorrent_torrent_ctl).
-behaviour(gen_fsm).
-define(CHECK_WAIT_TIME, 3000).
-define(LOG(X), io:write(X)).


%% API
-export([start_link/3,
         completed/1,
         pause_torrent/1,
         continue_torrent/1,
         check_torrent/1,
         valid_pieces/1,
         switch_mode/2]).

%% gproc registry entries
-export([register_server/1,
         lookup_server/1,
         await_server/1]).

%% gen_fsm callbacks
-export([init/1, 
         handle_event/3, 
         initializing/2, 
         started/2, 
         paused/2,
         handle_sync_event/4, 
         handle_info/3, 
         terminate/3,
         code_change/4]).

%% wish API
-export([get_permanent_wishes/1,
         get_wishes/1,
         set_wishes/2,
         wish_file/2,
         wish_piece/2,
         wish_piece/3,
         subscribe/3]).


-type bcode() :: etorrent_types:bcode().
-type torrent_id() :: etorrent_types:torrent_id().
-type file_id() :: etorrent_types:file_id().
-type pieceset() :: etorrent_pieceset:pieceset().
-type pieceindex() :: etorrent_types:piece_index().

%% If wish is [file_id()], for example, [1,2,3], then create
%% a mask which has all parts from files 1, 2, 3.
%% There is some code in `etorrent_io', that tells about how
%% numbering of files works.
-type wish() :: [file_id()] | file_id().
-type wish_list() :: [wish()].


-type file_wish()  :: [non_neg_integer()].
-type piece_wish() :: [non_neg_integer()].

-record(wish, {
    type :: file | piece,
    value :: file_wish() | piece_wish(),
    is_completed = false :: boolean(),
    %% Transient wishes are 
    %% * __small__  
    %% * __hidden__ for fast_resume module
    %% * always on top of the set of wishes.
    is_transient = false :: boolean(),
    subscribed = [] :: [pid()],
    pieceset :: pieceset()
}).

-record(state, {
    id          :: integer() ,
    torrent     :: bcode(),   % Parsed torrent file
    valid       :: pieceset(),
    hashes      :: binary(),
    info_hash   :: binary(),  % Infohash of torrent file
    peer_id     :: binary(),
    parent_pid  :: pid(),
    tracker_pid :: pid(),
    progress    :: pid(),
    pending     :: pid(),
    wishes = [] :: [#wish{}],
    interval    :: timer:interval(),
    mode = progress 
                :: 'progress' | 'endgame' | atom()
    }).



-spec register_server(torrent_id()) -> true.
register_server(TorrentID) ->
    etorrent_utils:register(server_name(TorrentID)).

-spec lookup_server(torrent_id()) -> pid().
lookup_server(TorrentID) ->
    etorrent_utils:lookup(server_name(TorrentID)).

-spec await_server(torrent_id()) -> pid().
await_server(TorrentID) ->
    etorrent_utils:await(server_name(TorrentID)).

server_name(TorrentID) ->
    {etorrent, TorrentID, control}.

%% @doc Start the server process
-spec start_link(integer(), {bcode(), string(), binary()}, binary()) ->
        {ok, pid()} | ignore | {error, term()}.
start_link(Id, {Torrent, TorrentFile, TorrentIH}, PeerId) ->
    gen_fsm:start_link(?MODULE, [self(), Id, {Torrent, TorrentFile, TorrentIH}, PeerId], []).

%% @doc Request that the given torrent is checked (eventually again)
%% @end
-spec check_torrent(pid()) -> ok.
check_torrent(Pid) ->
    gen_fsm:send_event(Pid, check_torrent).

%% @doc Tell the controlled the torrent is complete
%% @end
-spec completed(pid()) -> ok.
completed(Pid) ->
    gen_fsm:send_event(Pid, completed).

%% @doc Set the torrent on pause
%% @end
-spec pause_torrent(pid()) -> ok.
pause_torrent(Pid) ->
    gen_fsm:send_event(Pid, pause).

%% @doc Continue leaching or seeding 
%% @end
-spec continue_torrent(pid()) -> ok.
continue_torrent(Pid) ->
    gen_fsm:send_event(Pid, continue).

%% @doc Get the set of valid pieces for this torrent
%% @end
-spec valid_pieces(pid()) -> {ok, pieceset()}.
valid_pieces(Pid) ->
    gen_fsm:sync_send_all_state_event(Pid, valid_pieces).


switch_mode(Pid, Mode) ->
    gen_fsm:send_all_state_event(Pid, {switch_mode, Mode}).




%% =====================\/=== Wish API ===\/===========================

%% @doc Update wishlist.
%%      This function returns __minimized__ version of wishlist.
-spec set_wishes(torrent_id(), wish_list()) -> {ok, wish_list()}.

set_wishes(TorrentID, Wishes) ->
    {ok, FilteredWishes} = set_record_wishes(TorrentID, to_records(Wishes)),
    {ok, to_proplists(FilteredWishes)}.


-spec get_wishes(torrent_id()) -> {ok, wish_list()}.

get_wishes(TorrentID) ->
    {ok, Wishes} = get_record_wishes(TorrentID),
    {ok, to_proplists(Wishes)}.


get_permanent_wishes(TorrentID) ->
    {ok, Wishes} = get_record_wishes(TorrentID),
    {ok, to_proplists([X || X <- Wishes, not X#wish.is_transient])}.


%% @doc Add a file at top of wishlist.
%%      Added file will have highest priority inside this torrent.
-spec wish_file(torrent_id(), wish()) -> {ok, wish_list()}.

wish_file(TorrentID, [FileID]) when is_integer(FileID) ->
    wish_file(TorrentID, FileID);

wish_file(TorrentID, FileID) ->
    {ok, OldWishes} = get_record_wishes(TorrentID),
    Wish = #wish {
      type = file,
      value = FileID
    },
    NewWishes = [ Wish | OldWishes ],
    {ok, FilteredWishes} = set_record_wishes(TorrentID, NewWishes),
    {ok, to_proplists(FilteredWishes)}.


wish_piece(TorrentID, PieceID) ->
    wish_piece(TorrentID, PieceID, false).


wish_piece(TorrentID, PieceID, IsTemporary) ->
    {ok, OldWishes} = get_record_wishes(TorrentID),
    Wish = #wish {
      type = piece,
      value = PieceID,
      is_transient = IsTemporary
    },
    NewWishes = [ Wish | OldWishes ],
    {ok, FilteredWishes} = set_record_wishes(TorrentID, NewWishes),
    {ok, to_proplists(FilteredWishes)}.


%% @doc If the wish {Type, Value} will be completed,
%%      caller will receive {completed, Ref}.
%%      Use wish_file of wish_piece functions before calling this function.
subscribe(TorrentID, Type, Value) ->
    CtlSrv = lookup_server(TorrentID),
    gen_fsm:sync_send_all_state_event(CtlSrv, {subscribe, Type, Value}).

  
%% @doc Send information to the subscribed processes.
%% @private
alert_subscribed(Clients) ->
    [Pid ! {completed, Ref} || {Pid, Ref} <- Clients].


%% @private
get_record_wishes(TorrentID) ->
    CtlSrv = lookup_server(TorrentID),
    gen_fsm:sync_send_all_state_event(CtlSrv, get_wishes).


%% @private
set_record_wishes(TorrentID, Wishes) ->
    CtlSrv = lookup_server(TorrentID),
    gen_fsm:sync_send_all_state_event(CtlSrv, {set_wishes, Wishes}).


to_proplists(Records) ->
    [[{type, Type}
     ,{value, Value}
     ,{is_completed, IsCompleted}
     ,{is_transient, IsTransient}
     ] || #wish{ type = Type, 
                value = Value, 
         is_completed = IsCompleted,
         is_transient = IsTransient } <- Records].


to_records(Props) ->
    [#wish{type = proplists:get_value(type, X), 
          value = proplists:get_value(value, X),
   is_transient = proplists:get_value(is_transient, X, false)
   } || X <- Props, is_list(X)].


to_pieceset(TorrentID, #wish{ type = file, value = FileIds }) ->
    etorrent_info:get_mask(TorrentID, FileIds);

to_pieceset(TorrentID, #wish{ type = piece, value = List }) ->
    Pieceset = etorrent_info:get_mask(TorrentID, 0),
    Size = etorrent_pieceset:capacity(Pieceset),
    etorrent_pieceset:from_list(List, Size).


%% @private
validate_wishes(TorrentID, NewWishes, OldWishes, ValidPieces) ->
    val_(TorrentID, NewWishes, OldWishes, ValidPieces, []).
    

%% @doc Fix incomplete wishes.
%% @private
val_(Tid, [NewH|NewT], Old, Valid, Acc) ->
    case search_wish(NewH, Acc) of
    %% Signature is already used
    #wish{} -> 
        val_(Tid, NewT, Old, Valid, Acc);

    false ->
        Rec = case search_wish(NewH, Old) of
                %% New wish
                false ->
                    WishSet = to_pieceset(Tid, NewH),
                    Left = etorrent_pieceset:difference(WishSet, Valid),
                    IsCompleted = etorrent_pieceset:is_empty(Left),
                    NewH#wish {
                      is_completed = IsCompleted,
                      pieceset = WishSet
                    };

                RecI -> 
                    %% If old wish is transient and new is permanent, then set as permanent.
                    RecI#wish{is_transient=(NewH#wish.is_transient 
                                        and RecI#wish.is_transient)}
            end,
        val_(Tid, NewT, Old, Valid, [Rec|Acc])
    end;

val_(_Tid, [], _Old, _Valid, Acc) ->
    %% Transient wishes are always on top of a query.
    lists:keysort(#wish.is_transient, lists:reverse(Acc)).
    

%% @doc Check status of wishes.
%%      This function will be called periditionally.
check_completed(RecList, Valid) ->
    chk_(RecList, Valid, [], []).


chk_([H=#wish{ is_completed = true }|T], Valid, RecAcc, Ready) ->
   chk_(T, Valid, [H|RecAcc], Ready);

chk_([H|T], Valid, RecAcc, Ready) ->
    #wish{ is_completed = false, pieceset = WishSet, is_transient = IsTransient } = H,
 
    Left = etorrent_pieceset:difference(WishSet, Valid),
    IsCompleted = etorrent_pieceset:is_empty(Left),
    Rec = H#wish{ is_completed = IsCompleted },
    case {IsCompleted, IsTransient} of 
        %% Subscribed clients will be alerted. 
        %% Clear subscriptions.
        {true, true} -> 
            chk_(T, Valid, [Rec#wish{ subscribed=[] }|RecAcc], [Rec|Ready]);
        %% Subscribed clients will be alerted. 
        %% Delete element.
        {true, false} -> 
            chk_(T, Valid, RecAcc, [Rec|Ready]);
        {false, _} -> 
            chk_(T, Valid, [Rec|RecAcc], Ready)
    end;

chk_([], _Valid, RecAcc, Ready) ->
    {lists:reverse(RecAcc), lists:reverse(Ready)}.

    
%% @doc Save pid() as subscriber
%%      Client is {pid(), ref()}
%% @private
add_subscribtion(RecList, Type, Value, Client) ->
    sub_(RecList, Type, Value, Client, []).


sub_([#wish{ is_completed = true, type = Type, value = Value }|_]=T, 
        Type, Value, _Client, Acc) ->
    {completed, lists:reverse(Acc, T)};

sub_([H=#wish{ is_completed = false, type = Type, value = Value, 
        subscribed = S }|T], 
        Type, Value, Client, Acc) ->

    NewAcc = [H#wish { subscribed = [Client|S]} | Acc],
    {subscribed, lists:reverse(NewAcc, T)};

sub_([H|T], Type, Value, Client, Acc) ->
    sub_(T, Type, Value, Client, [H|Acc]);

sub_([], _Type, _Value, _Client, Acc) ->
    {completed, lists:reverse(Acc)}.


%% @doc Search the element with the same signature in the array.
%% @private
search_wish(#wish{ type = Type, value = Value },
       [H = #wish{ type = Type, value = Value } | _T]) ->
    H;

search_wish(El, [_H|T]) ->
    search_wish(El, T);

search_wish(_El, []) ->
    false.





%% =====================/\=== Wish API ===/\===========================
    

%% ====================================================================

%% @private
init([Parent, Id, {Torrent, TorrentFile, TorrentIH}, PeerId]) ->
    register_server(Id),
    etorrent_table:new_torrent(TorrentFile, TorrentIH, Parent, Id),
    HashList = etorrent_metainfo:get_pieces(Torrent),
    Hashes   = hashes_to_binary(HashList),
    InitState = #state{
        id=Id,
        torrent=Torrent,
        info_hash=TorrentIH,
        peer_id=PeerId,
        parent_pid=Parent,
        hashes=Hashes},
    {ok, initializing, InitState, 0}.

%% @private
initializing(timeout, #state{id=Id} = S0) ->
    Pending  = etorrent_pending:await_server(Id),
    S = S0#state{
        pending=Pending},

    case etorrent_table:acquire_check_token(Id) of
        false ->
            {next_state, initializing, S, ?CHECK_WAIT_TIME};
        true ->
            do_registration(S)
    end.


%% @private
started(check_torrent, State) ->
    #state{id=TorrentID, valid=Pieces, hashes=Hashes} = State,
    Indexes =  etorrent_pieceset:to_list(Pieces),
    Invalid =  [I || I <- Indexes, is_valid_piece(TorrentID, I, Hashes)],
    Invalid == [] orelse
        lager:info("Errornous piece: ~b", [Invalid]),
    {next_state, started, State};

started(completed, #state{id=Id, tracker_pid=TrackerPid} = S) ->
    etorrent_event:completed_torrent(Id),
    etorrent_tracker_communication:completed(TrackerPid),
    {next_state, started, S};

started(pause, #state{id=Id, interval=I} = SO) ->
%   etorrent_event:paused_torrent(Id),
    
    etorrent_table:statechange_torrent(Id, stopped),
    etorrent_event:stopped_torrent(Id),
    ok = etorrent_torrent:statechange(Id, [paused]),
    ok = etorrent_torrent_sup:pause(SO#state.parent_pid),
    {ok, cancel} = timer:cancel(I),

    S = SO#state{ tracker_pid = undefined, 
                     progress = undefined, 
                     interval = undefined },
    {next_state, paused, S};

started(continue, S) ->
    {next_state, started, S}.



paused(continue, #state{id=Id} = S) ->
    Ret = do_start(S),
    ok = etorrent_torrent:statechange(Id, [continue]),
    Ret;
paused(pause, S) ->
    {next_state, paused, S}.



%% @private
handle_event({switch_mode, Mode}, SN, S=#state{mode=Mode}) ->
    {next_state, SN, S};

handle_event({switch_mode, NewMode}, SN, S=#state{mode=OldMode}) ->
    lager:info("Switch mode: ~p => ~p ~n", [OldMode, NewMode]),
    #state{mode=OldMode, parent_pid=Sup, id=TorrentID,
        valid=ValidPieceSet} = S,

    ValidChunkArr = case OldMode of
        'progress' -> etorrent_progress:stored_chunks(TorrentID);
        _ -> array:new()
    end,

    etorrent_torrent_sup:stop_assignor(Sup),

    {ok, Assignor} = 
        case NewMode of
        'progress' ->
            #state{torrent=Torrent, 
                    wishes=Wishes} = S,
            Masks = wishes_to_masks(Wishes),

            %% Start the progress manager
            etorrent_torrent_sup:start_progress(
              Sup,
              TorrentID,
              Torrent,
              ValidPieceSet,
              Masks);

        'endgame' ->
            etorrent_torrent_sup:start_endgame(
              Sup,
              TorrentID)
        end,
        
    
    Peers = etorrent_peer_control:lookup_peers(TorrentID),
    [etorrent_download:switch_assignor(Peer, Assignor) || Peer <- Peers],

    {next_state, SN, S#state{mode=NewMode}};

handle_event(Msg, SN, S) ->
    lager:error("Problem: ~p~n", [Msg]),
    {next_state, SN, S}.



%% @private
handle_sync_event(valid_pieces, _, StateName, State) ->
    #state{valid=Valid} = State,
    {reply, {ok, Valid}, StateName, State};



handle_sync_event({subscribe, Type, Value}, {_Pid, Ref} = Client, SN, SD) ->
    OldWishes = SD#state.wishes,

    case add_subscribtion(OldWishes, Type, Value, Client) of
        {subscribed, NewWishes} ->
            {reply, {subscribed, Ref}, SN, SD#state{wishes=NewWishes}};

        {completed, _NewWishes} ->
            {reply, completed, SN, SD}
    end;

handle_sync_event(get_wishes, _From, SN, SD) ->
    Wishes = SD#state.wishes,
    {reply, {ok, Wishes}, SN, SD};

handle_sync_event({set_wishes, NewWishes}, _From, SN, 
    SD=#state{id=Id, wishes=OldWishes, valid=ValidPieces}) ->
    Wishes = validate_wishes(Id, NewWishes, OldWishes, ValidPieces),
    
    case SN of
        paused -> skip;
        _ -> 
            Masks = wishes_to_masks(Wishes),
            %% Tell to the progress manager about new list of wanted pieces
            etorrent_progress:set_wishes(Id, Masks)
    end,

    {reply, {ok, Wishes}, SN, SD#state{wishes=Wishes}}.


wishes_to_masks(Wishes) ->
    [X#wish.pieceset || X <- Wishes, not X#wish.is_completed ].


%% Tell the controller we have stored an index for this torrent file
%% @private
handle_info(check_completed, SN, SD=#state{valid = Valid, wishes = Wishes}) ->
    {NewWishes, CompletedWishes} = check_completed(Wishes, Valid),
    [alert_subscribed(Clients) 
        || #wish{subscribed = Clients} 
        <- CompletedWishes],
    {next_state, SN, SD#state{wishes = NewWishes}};

handle_info({piece, {stored, Index}}, started, State) ->
    ?LOG({c,s, Index}),
    #state{id=TorrentID, 
        hashes=Hashes, 
        progress=Progress, 
        valid=ValidPieces} = State,
    Piecehash = fetch_hash(Index, Hashes),
    case etorrent_io:check_piece(TorrentID, Index, Piecehash) of
        {ok, PieceSize} ->
            Peers = etorrent_peer_control:lookup_peers(TorrentID),
            ok = etorrent_torrent:statechange(TorrentID, 
                [{subtract_left, PieceSize}]),
            ok = etorrent_piecestate:valid(Index, Peers),
            ok = etorrent_piecestate:valid(Index, Progress),
            NewValidState = etorrent_pieceset:insert(Index, ValidPieces),
            {next_state, started, State#state { valid = NewValidState }};
        wrong_hash ->
            Peers = etorrent_peer_control:lookup_peers(TorrentID),
            ok = etorrent_piecestate:invalid(Index, Progress),
            ok = etorrent_piecestate:unassigned(Index, Peers),
            {next_state, started, State}
    end;

handle_info(Info, StateName, State) ->
    lager:error("Unknown handle_info event: ~p", [Info]),
    {next_state, StateName, State}.


%% @private
terminate(_Reason, _StateName, _S) ->
    ok.

%% @private
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.






%% --------------------------------------------------------------------

do_registration(S=#state{id=Id, torrent=Torrent, hashes=Hashes}) ->
    %% @todo: Try to coalesce some of these operations together.

    %% Read the torrent, check its contents for what we are missing
    FastResumePL = etorrent_fast_resume:query_state(Id),

    etorrent_table:statechange_torrent(Id, checking),
    etorrent_event:checking_torrent(Id),
    ValidPieces = read_and_check_torrent(Id, Hashes, FastResumePL),
    Left = calculate_amount_left(Id, ValidPieces, Torrent),
    NumberOfPieces = etorrent_pieceset:capacity(ValidPieces),
    NumberOfValidPieces = etorrent_pieceset:size(ValidPieces),
    NumberOfMissingPieces = NumberOfPieces - NumberOfValidPieces,

    AU = proplists:get_value(uploaded, FastResumePL, 0),
    AD = proplists:get_value(downloaded, FastResumePL, 0),
    TState = proplists:get_value(state, FastResumePL, unknown),
    Wishes = proplists:get_value(wishes, FastResumePL, []),

    %% Add a torrent entry for this torrent.
    %% @todo Minimize calculation in `etorrent_torrent' module.
    ok = etorrent_torrent:new(
           Id,
           [{uploaded, 0},
            {downloaded, 0},
            {all_time_uploaded, AU},
            {all_time_downloaded, AD},
            {left, Left},
            {total, etorrent_metainfo:get_length(Torrent)},
            {is_private, etorrent_metainfo:is_private(Torrent)},
            {pieces, NumberOfValidPieces},
            {missing, NumberOfMissingPieces},
            {state, TState}]),

    WishRecordSet = try
        validate_wishes(Id, to_records(Wishes), [], ValidPieces)
        catch error:Reason ->
        error_logger:error_msg("Wishes from fast_resume "
            "module are invalidate~n ~w", [Reason]),
        []
    end,
    NewState = S#state{ valid=ValidPieces, wishes = WishRecordSet },

    case TState of
        paused ->
            etorrent_table:statechange_torrent(Id, stopped),
            etorrent_event:stopped_torrent(Id),
            {next_state, paused, NewState};
        _ -> 
        do_start(NewState)
    end.


do_start(S=#state{id=Id, torrent=Torrent, valid=ValidPieces, wishes=Wishes}) ->
    Masks = wishes_to_masks(Wishes),

    %% Start the progress manager
    {ok, ProgressPid} =
        etorrent_torrent_sup:start_progress(
          S#state.parent_pid,
          Id,
          Torrent,
          ValidPieces,
          Masks),

    %% Update the tracking map. This torrent has been started.
    %% Altering this state marks the point where we will accept
    %% Foreign connections on the torrent as well.
    etorrent_table:statechange_torrent(Id, started),
    etorrent_event:started_torrent(Id),

    %% Start the tracker
    {ok, TrackerPid} =
        etorrent_torrent_sup:start_child_tracker(
          S#state.parent_pid,
          etorrent_metainfo:get_url(Torrent),
          S#state.info_hash,
          S#state.peer_id,
          Id),

    etorrent_torrent_sup:start_peer_sup(S#state.parent_pid, Id),

    {ok, Timer} = timer:send_interval(10000, check_completed),

    NewState = S#state{tracker_pid = TrackerPid,
                          progress = ProgressPid,
                          interval = Timer },

    {next_state, started, NewState}.


%% @todo run this when starting:
%% etorrent_event:seeding_torrent(Id),

%% --------------------------------------------------------------------

%% @todo Does this function belong here?
calculate_amount_left(TorrentID, Valid, Torrent) ->
    Total = etorrent_metainfo:get_length(Torrent),
    Indexes = etorrent_pieceset:to_list(Valid),
    Sizes = [begin
        {ok, Size} = etorrent_info:piece_size(TorrentID, I),
        Size
    end || I <- Indexes],
    Downloaded = lists:sum(Sizes),
    Total - Downloaded.


% @doc Create an initial pieceset() for the torrent.
% <p>Given a TorrentID and a binary of the Hashes of the torrent,
%   form a `pieceset()' by querying the fast_resume system. If the fast resume
%   system knows what is going on, use that information. Otherwise, form all possible
%   pieces, but filter them through a correctness checker.</p>
% @end
-spec read_and_check_torrent(integer(), binary(), [{atom(), term()}]) -> pieceset().
read_and_check_torrent(TorrentID, Hashes, PL) ->
    ok = etorrent_io:allocate(TorrentID),
    Numpieces = num_hashes(Hashes),

    Stage = to_stage(PL),

    case Stage of
        unknown -> 
            All  = etorrent_pieceset:full(Numpieces),
            filter_pieces(TorrentID, All, Hashes);
        completed -> 
            etorrent_pieceset:full(Numpieces);
        incompleted ->
            Bin = proplists:get_value(bitfield, PL),
            etorrent_pieceset:from_binary(Bin, Numpieces)
    end.
    
    
%% @doc This simple function transforms the stored state of the torrent 
%%      to the stage of the downloading process. PL is stored in 
%%      the `etorrent_fast_resume' module.
-spec to_stage([{atom(), term()}]) -> atom().
to_stage([]) -> unknown;
to_stage(PL) -> 
    case proplists:get_value(bitfield, PL) of
    undefined ->
        completed;
    _ ->
        incompleted
    end.
        


% @doc Filter a pieceset() w.r.t data on disk.
% <p>Given a set of pieces to check, `ToCheck', check each piece in there for validity.
%  return a pieceset() where all invalid pieces have been filtered out.</p>
% @end
-spec filter_pieces(torrent_id(), pieceset(), binary()) -> pieceset().
filter_pieces(TorrentID, ToCheck, Hashes) ->
    Indexes = etorrent_pieceset:to_list(ToCheck),
    ValidIndexes = [I || I <- Indexes, is_valid_piece(TorrentID, I, Hashes)],
    Numpieces = etorrent_pieceset:capacity(ToCheck),
    etorrent_pieceset:from_list(ValidIndexes, Numpieces).


-spec is_valid_piece(torrent_id(), pieceindex(), binary()) -> boolean().
is_valid_piece(TorrentID, Index, Hashes) ->
    Hash = fetch_hash(Index, Hashes),
    case etorrent_io:check_piece(TorrentID, Index, Hash) of
        {ok, _}    -> true;
        wrong_hash -> false
    end.


-spec hashes_to_binary([<<_:160>>]) -> binary().
hashes_to_binary(Hashes) ->
    hashes_to_binary(Hashes, <<>>).


hashes_to_binary([], Acc) ->
    Acc;
hashes_to_binary([H=(<<_:160>>)|T], Acc) ->
    hashes_to_binary(T, <<Acc/binary, H/binary>>).


fetch_hash(Piece, Hashes) ->
    Offset = 20 * Piece,
    case Hashes of
        <<_:Offset/binary, Hash:20/binary, _/binary>> -> Hash;
        _ -> erlang:error(badarg)
    end.


num_hashes(Hashes) ->
    byte_size(Hashes) div 20.


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

hashes_to_binary_test_() ->
    Input = [<<1:160>>, <<2:160>>, <<3:160>>],
    Bin = hashes_to_binary(Input),
    [?_assertEqual(<<1:160>>, fetch_hash(0, Bin)),
     ?_assertEqual(<<2:160>>, fetch_hash(1, Bin)),
     ?_assertEqual(<<3:160>>, fetch_hash(2, Bin)),
     ?_assertEqual(3, num_hashes(Bin)),
     ?_assertError(badarg, fetch_hash(-1, Bin)),
     ?_assertError(badarg, fetch_hash(3, Bin))].


-endif.
