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

%% Privete API
-export([srv_name/0,
         update/0]).

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

-spec srv_name() -> atom().
srv_name() ->
    ?MODULE.

%% @doc
%% Create a snapshot of all torrents that are loaded into etorrent
%% at the time when this function is called.
%% @end
-spec update() -> ok.
update() ->
    gen_server:call(srv_name(), update).

%% ==================================================================

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

handle_call(update, _, State) ->
    %% Run a persistence operation on all torrents
    %% TODO - in the ETS implementation the state of all inactive
    %%        torrents was flushed out on each persitance operation.
    _ = [begin
        TorentID = proplists:get_value(id, Props)
        Filename = proplists:get_value(filename, Props),
        track_torrent(TorrentID, Filename)
    end || Props <- etorrent_table:all_torrents()],
    ok.

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

upgrade(1, St) ->
    upgrade1(St).

%% Enter a torrent into the tracking table
track_torrent(ID, Filename, Table) ->
    case etorrent_torrent:lookup(ID) of
        not_found ->
            ignore;
        {value, Props} ->
            UploadTotal = proplists:get_value(all_time_uploaded, Props),
            UploadDiff  = proplists:get_value(uploaded, Props),
	        Uploaded    = UploadTotal + UploadDiff,

            DownloadTotal = proplists:get_value(all_time_downloaded, Props),
            DownloadDiff  = proplists:get_value(downloaded, Props),
	        Downloaded    = DownloadTotal + DownloadDiff,

	        case proplists:get_value(state, Props) of
		        unknown ->
                    ignore;
		        seeding ->
                    dets:insert(Table,
				        {Filename, [
                            {state, seeding},
					        {uploaded, Uploaded},
					        {downloaded, Downloaded}]});
		         _  ->
                    dets:insert(Table,
			            {Filename, [
                            {state, {bitfield, etorrent_piece_mgr:bitfield(Id)}},
				            {uploaded, Uploaded},
				            {downloaded, Downloaded}]})
	        end
    end.



%% Upgrade from version 1
upgrade1(St) ->
    [{state, St},
     {uploaded, 0},
     {downloaded, 0}].
