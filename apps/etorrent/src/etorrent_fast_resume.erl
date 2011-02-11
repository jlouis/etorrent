%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Periodically record piece state to disk.
%% <p>The `fast_resume' code is responsible for persisting the state of
%% downloaded pieces to disk every 5 minutes. This means that if we
%% crash, we are at worst 5 minutes back in time for the downloading
%% of a torrent.</p>
%% <p>When a torrent is initially started, the `fast_resume' is
%% consulted for an eventual piece state. At the moment this piece
%% state is believed blindly if present.</p>
%% @end
%% @todo Improve the situation and check strength.
-module(etorrent_fast_resume).
-behaviour(gen_server).

-include("types.hrl").
-include("log.hrl").

%% API
-export([start_link/0,
         query_state/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {
    table=none :: atom()
}).

-define(SERVER, ?MODULE).
-ignore_xref([{start_link, 0}]).

%%====================================================================

%% @doc Start up the server
%% @end
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Query for the state of TorrentId, Id.
%% <p>The function returns one of several possible values:</p>
%% <dl>
%%     <dt>unknown</dt>
%%     <dd>The torrent is in an unknown state. This means we know nothing
%%         in particular about the torrent and we should simply load it as
%%         if we had just started it</dd>
%%
%%     <dt>seeding</dt>
%%     <dd>We are currently seeding this torrent</dd>
%%
%%     <dt>{bitfield, BF}</dt>
%%     <dd>Here is the bitfield of known good pieces. The rest are in
%%         an unknown state.</dd>
%% </dl>
%% @end
-spec query_state(integer()) -> unknown | {value, [{term(), term()}]}.
query_state(Id) ->
        gen_server:call(?SERVER, {query_state, Id}).

%% ==================================================================

%% Enter a torrent into the tracking table
track_torrent(Id, FName) ->
    case etorrent_torrent:lookup(Id) of
        not_found -> ignore;
        {value, PL} ->

	    Uploaded = proplists:get_value(uploaded, PL) +
		       proplists:get_value(all_time_uploaded, PL),
	    Downloaded = proplists:get_value(downloaded, PL) +
		         proplists:get_value(all_time_downloaded, PL),
	    case proplists:get_value(state, PL) of
		unknown -> ignore;
		seeding -> ets:insert(?MODULE,
				      {FName, [{state, seeding},
					       {uploaded, Uploaded},
					       {downloaded, Downloaded}]});
		_Other  -> ets:insert(
			     ?MODULE,
			     {FName, [{state,
				       {bitfield, etorrent_piece_mgr:bitfield(Id)}},
				      {uploaded, Uploaded},
				      {downloaded, Downloaded}]})
	    end
    end.

%% Enter all torrents into a tracking table
track_in_ets_table(Lst) when is_list(Lst) ->
    [track_torrent(Id, FN) || {Id, FN} <- Lst].

%% Run a persistence operation
persist_to_disk() ->
    PLS = etorrent_table:all_torrents(),
    track_in_ets_table([{proplists:get_value(id, P),
			 proplists:get_value(filename, P)} || P <- PLS]),
    F  = etorrent_config:fast_resume_file(),
    ok = filelib:ensure_dir(F),
    ok = ets:tab2file(etorrent_fast_resume, F, [{extended_info, [object_count, md5sum]}]),
    ok.

upgrade(1, St) ->
    upgrade1(St).

%% Upgrade from version 1
upgrade1(St) ->
    [{state, St},
     {uploaded, 0},
     {downloaded, 0}].

%% ==================================================================

%% @private
init([]) ->
    %% TODO - check for errors when opening the dets table
    Statefile  = etorrent_config:fast_resume_file(),
    Statetable = dets:init_table(Statefile),
    InitState  = #state{table=Statetable},
    {ok, InitState}.

handle_call({query_state, Id}, _From, State) ->
    #state{table=Table} = State,
    {value, Properties} = etorrent_table:get_torrent(Id),
    Torrentfile = proplists:get_value(filename, Properties),
    Reply = case dets:lookup(Table, Torrentfile) of
        [] ->
            unknown;
        [{_, FSPL}] when is_list(FSPL) ->
            {value, FSPL};
	    [{_, St}] ->
            {value, upgrade(1, St)}
    end,
    {reply, Reply, State};

handle_call(_, _, State) ->
    {reply, ok, State}.

handle_cast(_, State) ->
    {noreply, State}.

handle_info(_, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_, State, _) ->
    {ok, State}.

