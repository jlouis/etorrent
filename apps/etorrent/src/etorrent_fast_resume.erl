%%%-------------------------------------------------------------------
%%% File    : etorrent_fast_resume.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Fast resume process
%%%
%%% Created : 16 Jul 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------
-module(etorrent_fast_resume).

-behaviour(gen_server).

-include("types.hrl").
-include("log.hrl").

%% API
-export([start_link/0, query_state/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {}).

-define(SERVER, ?MODULE).
-define(PERSIST_TIME, timer:seconds(300)). % Every 300 secs, may be done configurable.
-ignore_xref([{start_link, 0}]).
%%====================================================================
%% @doc Start up the server
%% @end
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Query for the state of TorrentId, Id.
%% <p>The function returns one of several possible values:</p>
%% <dl><dt>unknown</dt>
%%     <dd>The torrent is in an unknown state. This means we know nothing
%%         in particular about the torrent and we should simply load it as
%%         if we had just started it</dd>
%%     <dt>seeding</dt><dd>We are currently seeding this torrent</dd>
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
    {ok, F} = application:get_env(etorrent, fast_resume_file),
    ok = ets:tab2file(etorrent_fast_resume, F, [{extended_info, [object_count, md5sum]}]),
    ok.

%% ==================================================================

init([]) ->
    process_flag(trap_exit, true),
    {ok, F} = application:get_env(etorrent, fast_resume_file),
    X = ets:file2tab(F, [{verify, true}]),
    _ = case X of
        {ok, etorrent_fast_resume} -> true;
        E ->
            ?INFO([fast_resume_no_data, E]),
            _ = ets:new(etorrent_fast_resume, [named_table, protected])
    end,
    erlang:send_after(?PERSIST_TIME, self(), persist),
    {ok, #state{}}.

handle_call({query_state, Id}, _From, S) ->
    {value, PL} = etorrent_table:get_torrent(Id),
    case ets:lookup(etorrent_fast_resume, proplists:get_value(filename, PL)) of
        [] -> {reply, unknown, S};
        [{_, FSPL}] when is_list(FSPL) -> {reply, {value, FSPL}, S};
	[{_, St}] -> {reply, {value, upgrade(1, St)}, S}
    end;
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(persist, S) ->
    persist_to_disk(),
    erlang:send_after(?PERSIST_TIME, self(), persist),
    {noreply, S};
handle_info(_Info, State) ->
    {noreply, State}.


terminate(normal, _State) ->
    persist_to_disk(),
    ok;
terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

upgrade(1, St) ->
    upgrade1(St).

%% Upgrade from version 1
upgrade1(St) ->
    [{state, St},
     {uploaded, 0},
     {downloaded, 0}].
