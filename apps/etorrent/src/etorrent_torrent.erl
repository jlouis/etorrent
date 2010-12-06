%%%-------------------------------------------------------------------
%%% File    : etorrent_torrent.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Library for manipulating the torrent table.
%%%
%%% Created : 15 Jun 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_torrent).

-behaviour(gen_server).

%% Counter for how many pieces is missing from this torrent
-record(c_pieces, {id :: non_neg_integer(), % Torrent id
                   missing :: non_neg_integer()}). % Number of missing pieces
%% API
-export([start_link/0,
         new/3, all/0, statechange/2,
         num_pieces/1, decrease_not_fetched/1,
         is_seeding/1, seeding/0,
         lookup/1, is_endgame/1]).

-export([init/1, handle_call/3, handle_cast/2, code_change/3,
         handle_info/2, terminate/2]).

%% The type of torrent records.

-type(torrent_state() :: 'leeching' | 'seeding' | 'endgame' | 'unknown').
%% A single torrent is represented as the 'torrent' record
-record(torrent,
	{ %% Unique identifier of torrent, monotonically increasing
	  id :: non_neg_integer(),
	  %% How many bytes are there left before we have the full torrent
	  left = unknown :: non_neg_integer(),
	  %% How many bytes are there in total
	  total  :: non_neg_integer(),
	  %% How many bytes have we uploaded
	  uploaded :: non_neg_integer(),
	  %% How many bytes have we downloaded
	  downloaded :: non_neg_integer(),
	  %% Uploaded and downloaded bytes, all time
	  all_time_uploaded = 0 :: non_neg_integer(),
	  all_time_downloaded = 0 :: non_neg_integer(),
	  %% Number of pieces in torrent
	  pieces = unknown :: non_neg_integer() | 'unknown',
	  %% How many people have a completed file?
	  seeders = 0 :: non_neg_integer(),
	  %% How many people are downloaded
	  leechers = 0 :: non_neg_integer(),
	  rate_sparkline = [0.0],
	  state :: torrent_state()}).

-define(SERVER, ?MODULE).
-define(TAB, ?MODULE).
-record(state, { monitoring }).
-ignore_xref([{'start_link', 0}]).

%% ====================================================================

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

% @doc Initialize a torrent
% <p>The torrent entry for Id with the tracker
%   state as given. Pieces is the number of pieces for this torrent.
% </p>
% <p><emph>Precondition:</emph> The #piece table has been filled with the torrents pieces.</p>
% @end
-spec new(integer(),
       {{uploaded, integer()},
        {downloaded, integer()},
	{all_time_uploaded, non_neg_integer()},
	{all_time_downloaded, non_neg_integer()},
        {left, integer()},
        {total, integer()}}, integer()) -> ok.
new(Id, Info, NPieces) ->
    gen_server:call(?SERVER, {new, Id, Info, NPieces}).

% @doc Return all torrents, sorted by Id
% @end
-spec all() -> [[{term(), term()}]].
all() ->
    gen_server:call(?SERVER, all).

% @doc Request a change of state for the torrent
% <p>The specific What part is documented as the alteration() type
% in the module.
% </p>
% @end
-type alteration() :: unknown
                    | endgame
                    | {add_downloaded, integer()}
                    | {add_upload, integer()}
                    | {subtract_left, integer()}
                    | {tracker_report, integer(), integer()}.
-spec statechange(integer(), [alteration()]) -> ok.
statechange(Id, What) ->
    gen_server:call(?SERVER, {statechange, Id, What}).

% @doc Return the number of pieces for torrent Id
% @end
-spec num_pieces(integer()) -> {value, integer()}.
num_pieces(Id) ->
    gen_server:call(?SERVER, {num_pieces, Id}).

%% @doc Return a property list of the torrent identified by Id
%% @end
-spec lookup(integer()) ->
		    not_found | {value, [{term(), term()}]}.
lookup(Id) ->
    case ets:lookup(?TAB, Id) of
	[] -> not_found;
	[M] -> {value, proplistify(M)}
    end.

% @doc Returns true if the torrent is a seeding torrent
% @end
-spec is_seeding(integer()) -> boolean().
is_seeding(Id) ->
    {value, S} = lookup(Id),
    proplists:get_value(state, S) =:= seeding.

% @doc Returns all torrents which are currently seeding
% @end
-spec seeding() -> {value, [integer()]}.
seeding() ->
    Torrents = all(),
    {value, [proplists:get_value(id, T) ||
		T <- Torrents,
		proplists:get_value(state, T) =:= seeding]}.

% @doc Track that we downloaded a piece
%  <p>As a side-effect, this call eventually updates the endgame state</p>
% @end
-spec decrease_not_fetched(integer()) -> ok.
decrease_not_fetched(Id) ->
    gen_server:call(?SERVER, {decrease, Id}).


% @doc Returns true if the torrent is in endgame mode
% @end
-spec is_endgame(integer()) -> boolean().
is_endgame(Id) ->
    case ets:lookup(?TAB, Id) of
        [T] -> T#torrent.state =:= endgame;
        [] -> false % The torrent isn't there anymore.
    end.

%% =======================================================================

init([]) ->
    _ = ets:new(?TAB, [protected, named_table,
                                   {keypos, 2}]),
    _ = ets:new(etorrent_c_pieces, [protected, named_table,
                                    {keypos, 2}]),
    erlang:send_after(timer:seconds(60),
		      self(),
		      rate_sparkline_update),
    {ok, #state{ monitoring = dict:new() }}.

handle_call({new, Id, {{uploaded, U}, {downloaded, D},
		       {all_time_uploaded, AU},
		       {all_time_downloaded, AD},
                       {left, L}, {total, T}}, NPieces}, {Pid, _Tag}, S) ->
    State = case L of
                0 -> etorrent_event_mgr:seeding_torrent(Id),
                     seeding;
                _ -> leeching
            end,
    true = ets:insert_new(?TAB,
                #torrent { id = Id,
                           left = L,
                           total = T,
                           uploaded = U,
                           downloaded = D,
			   all_time_uploaded = AU,
			   all_time_downloaded = AD,
                           pieces = NPieces,
                           state = State }),
    Missing = etorrent_piece_mgr:num_not_fetched(Id),
    true = ets:insert_new(etorrent_c_pieces, #c_pieces{ id = Id, missing = Missing}),
    R = erlang:monitor(process, Pid),
    NS = S#state { monitoring = dict:store(R, Id, S#state.monitoring) },
    {reply, ok, NS};
handle_call(all, _F, S) ->
    Q = all(#torrent.id),
    {reply, Q, S};
handle_call({num_pieces, Id}, _F, S) ->
    [R] = ets:lookup(?TAB, Id),
    {reply, {value, R#torrent.pieces}, S};
handle_call({statechange, Id, What}, _F, S) ->
    Q = state_change(Id, What),
    {reply, Q, S};
handle_call({decrease, Id}, _F, S) ->
    N = ets:update_counter(etorrent_c_pieces, Id, {#c_pieces.missing, -1}),
    case N of
        0 ->
            state_change(Id, [endgame]),
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
    ets:delete(?TAB, Id),
    ets:delete(etorrent_c_pieces, Id),
    {noreply, S#state { monitoring = dict:erase(Ref, S#state.monitoring) }};
handle_info(rate_sparkline_update, S) ->
    for_each_torrent(fun update_sparkline_rate/1),
    erlang:send_after(timer:seconds(60), self(), rate_sparkline_update),
    {noreply, S};
handle_info(_M, S) ->
    {noreply, S}.

code_change(_OldVsn, S, _Extra) ->
    {ok, S}.

terminate(_Reason, _S) ->
    ok.

%% -----------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: all(Pos) -> Rows
%% Description: Return all torrents, sorted by Pos
%%--------------------------------------------------------------------
all(Pos) ->
    Objects = ets:match_object(?TAB, '$1'),
    lists:keysort(Pos, Objects),
    [proplistify(O) || O <- Objects].

proplistify(T) ->
    [{id, T#torrent.id},
     {total, T#torrent.total},
     {left,  T#torrent.left},
     {uploaded, T#torrent.uploaded},
     {downloaded, T#torrent.downloaded},
     {all_time_downloaded, T#torrent.all_time_downloaded},
     {all_time_uploaded,   T#torrent.all_time_uploaded},
     {leechers, T#torrent.leechers},
     {seeders, T#torrent.seeders},
     {state, T#torrent.state},
     {rate_sparkline, T#torrent.rate_sparkline}].


%% @doc Run function F on each torrent
%% @end
for_each_torrent(F) ->
    Objects = ets:match_object(?TAB, '$1'),
    lists:foreach(F, Objects).

%% @doc Update the rate_sparkline field in the #torrent{} record.
%% @end
update_sparkline_rate(Row) ->
    case Row#torrent.state of
        X when X =:= seeding orelse X =:= leeching ->
            {ok, R} = etorrent_rate_mgr:get_torrent_rate(
                            Row#torrent.id, X),
            SL = update_sparkline(R, Row#torrent.rate_sparkline),
            ets:insert(?TAB, Row#torrent { rate_sparkline = SL }),
            ok;
        _ ->
            ok
    end.

%% @doc Add a new rate to a sparkline, and trim if it gets too big
%% @end
update_sparkline(NR, L) ->
    case length(L) > 25 of
        true ->
            {F, _} = lists:split(20, L),
            [NR | F];
        false ->
            [NR | L]
    end.

%% Change the state of the torrent with Id, altering it by the "What" part.
%% Precondition: Torrent exists in the ETS table.
state_change(_Id, []) ->
    ok;
state_change(Id, [What | Rest]) ->
    [T] = ets:lookup(?TAB, Id),
    New = case What of
              unknown ->
                  T#torrent{state = unknown};
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
			  ControlPid = gproc:lookup_local_name({torrent, Id, control}),
			  etorrent_t_control:completed(ControlPid),
                          T#torrent { left = 0, state = seeding,
				      rate_sparkline = [0.0] };
                      N when N =< T#torrent.total ->
                          T#torrent { left = N }
                  end;
              {tracker_report, Seeders, Leechers} ->
                  T#torrent{seeders = Seeders, leechers = Leechers}
          end,
    ets:insert(?TAB, New),
    case {T#torrent.state, New#torrent.state} of
        {leeching, seeding} ->
            etorrent_event_mgr:seeding_torrent(Id),
            ok;
        _ ->
            ok
    end,
    state_change(Id, Rest).
