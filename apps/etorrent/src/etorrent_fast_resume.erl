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
    interval=3000,
    table=none :: atom()
}).

-ignore_xref([{start_link, 0}]).

%%====================================================================

%% @doc Start up the server
%% @end
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, srv_name()}, ?MODULE, [], []).

%% @doc Query for the state of TorrentID, ID.
%% <p>The function returns one of several possible values:</p>
%% <dl>
%%      <dt>unknown</dt>
%%      <dd>
%%         The torrent is in an unknown state. This means we know nothing
%%         in particular about the torrent and we should simply load it as
%%         if we had just started it
%%      </dd>
%%
%%      <dt>seeding</dt>
%%      <dd>
%%          We are currently seeding this torrent
%%      </dd>
%%
%%      <dt>{bitfield, BF}</dt>
%%      <dd>
%%          Here is the bitfield of known good pieces.
%%          The rest are in an unknown state.
%%      </dd>
%% </dl>
%% @end
-spec query_state(integer()) -> unknown | {value, [{term(), term()}]}.
query_state(ID) ->
    gen_server:call(srv_name(), {query_state, ID}).

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

%% @private
init([]) ->
    %% TODO - check for errors when opening the dets table
    Statefile  = etorrent_config:fast_resume_file(),
    {ok, Statetable} = case dets:open_file(Statefile, []) of
        {ok, Table} ->
            {ok, Table};
        %% An old spoolfile may have been created using ets:tab2file.
        %% Removing it and reopening the dets table works in this case.
        {error,{not_a_dets_file, _}} ->
            file:delete(Statefile),
            dets:open_file(Statefile, [])
    end,
    InitState  = #state{table=Statetable},
    #state{interval=Interval} = InitState,
    _ = timer:apply_interval(Interval, ?MODULE, update, []),
    {ok, InitState}.

%% @private
handle_call({query_state, ID}, _From, State) ->
    #state{table=Table} = State,
    {value, Properties} = etorrent_table:get_torrent(ID),
    Torrentfile = proplists:get_value(filename, Properties),
    Reply = case dets:lookup(Table, Torrentfile) of
        [] ->
            unknown;
        [{_, Torrentstate}] ->
            {value, Torrentstate}
    end,
    {reply, Reply, State};

handle_call(update, _, State) ->
    %% Run a persistence operation on all torrents
    %% TODO - in the ETS implementation the state of all inactive
    %%        torrents was flushed out on each persitance operation.
    #state{table=Table} = State,
    _ = [begin
        TorrentID = proplists:get_value(id, Props),
        Filename  = proplists:get_value(filename, Props),
        track_torrent(TorrentID, Filename, Table)
    end || Props <- etorrent_table:all_torrents()],
    {reply, ok, State}.

%% @private
handle_cast(_, State) ->
    {noreply, State}.

%% @private
handle_info(_, State) ->
    {noreply, State}.

%% @private
terminate(_, _) ->
    ok.

%% @private
code_change(_, State, _) ->
    {ok, State}.

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
                    TorrentPid = etorrent_torrent_ctl:lookup_server(ID),
                    {ok, Valid} = etorrent_torrent_ctl:valid_pieces(TorrentPid),
                    Bitfield = etorrent_pieceset:to_binary(Valid),
                    dets:insert(Table,
			            {Filename, [
                                                {state, {bitfield, Bitfield}},
                                                {uploaded, Uploaded},
                                                {downloaded, Downloaded}]})
	        end
    end.
