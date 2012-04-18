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


%% API
-export([start_link/0,
         list/0,
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
          interval = timer:seconds(30) :: integer(),
          table    = none :: atom()
}).

%%====================================================================

%% @doc Start up the server
%% @end
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, srv_name()}, ?MODULE, [], []).

%% @doc Query the state of the whole table
%%   This call will print the contents of the internal table via io
%% @end
-spec list() -> ok.
list() ->
    gen_server:call(srv_name(), list).

%% @doc Query for the state of TorrentID, ID.
%% <p>The function returns the proplist.
%% [{state, State},
%%  {bitfield, Bitfield}, optional
%%  {uploaded, Uploaded},
%%  {downloaded, Downloaded}]

%% State has one of several possible values:</p>
%% <dl>
%%      <dt>unknown</dt>
%%      <dd>
%%         The torrent is in an unknown state. This means we know nothing
%%         in particular about the torrent and we should simply load it as
%%         if we had just started it
%%      </dd>
%%
%%      <dt>seeding, paused, Left = 0</dt>
%%      <dd>
%%          We are currently seeding this torrent.
%%      </dd>
%%
%%      <dt>leaching, paused, Left > 0</dt>
%%      <dd>
%%          Here is the bitfield of known good pieces.
%%          The rest are in an unknown state.
%%      </dd>
%% </dl>
%% @end
-spec query_state(integer()) -> [{term(), term()}].
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
    {ok, Statetable} =
        case dets:open_file(Statefile, []) of
            {ok, Table} ->
                {ok, Table};
            %% An old spoolfile may have been created using ets:tab2file.
            %% Removing it and reopening the dets table works in this case.
            {error,{not_a_dets_file, _}} ->
                etorrent_event:notify(statefile_is_not_dets),
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
    TorrentFile = proplists:get_value(filename, Properties),

    Reply = case dets:lookup(Table, TorrentFile) of
			[{_, [_|_] = TorrentState}] ->
				case proplists:get_value('state', TorrentState, 0) of
				X when is_atom(X) -> 
					% check the fact that state is atom, not a tuple.
					TorrentState;
				_ -> 
					% data is from old version of code.
					[]
				end;

			_ -> 
				% there is no data.
				[]
		end,

    {reply, Reply, State};

handle_call(list, _, #state { table = Table } = State) ->
    Traverser = fun(T) ->
                        io:format("~p~n", [T]),
                        continue
                end,
    dets:traverse(Table, Traverser),
    {reply, ok, State};
handle_call(update, _, State) ->
    %% Run a persistence operation on all torrents
    %% TODO - in the ETS implementation the state of all inactive
    %%        torrents was flushed out on each persitance operation.
    #state{table=Table} = State,
    [begin
         TorrentID = proplists:get_value(id, Props),
         Filename  = proplists:get_value(filename, Props),
         track_torrent(TorrentID, Filename, Table)
     end || Props <- etorrent_table:all_torrents()],
    dets:sync(Table),
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
track_torrent(Id, Filename, Table) ->
    case etorrent_torrent:lookup(Id) of
        not_found ->
            ignore;
        {value, Props} ->
            case form_entry(Id, Props) of
                ignore -> ignore;
                Entry -> 
                    dets:insert(Table, {Filename, Entry})
            end
    end.

%% @private
form_entry(Id, Props) ->
    UploadTotal   = proplists:get_value(all_time_uploaded, Props),
    UploadDiff    = proplists:get_value(uploaded, Props),
    Uploaded      = UploadTotal + UploadDiff,

    DownloadTotal = proplists:get_value(all_time_downloaded, Props),
    DownloadDiff  = proplists:get_value(downloaded, Props),
    Downloaded    = DownloadTotal + DownloadDiff,

    Left = proplists:get_value(left, Props),

    case proplists:get_value(state, Props) of
        %% not prepared
        unknown ->
            ignore;

        %% downloaded
        State when Left =:= 0 ->
            [{state, State}
            ,{uploaded, Uploaded}
            ,{downloaded, Downloaded}];

        %% not downloaded
        State ->
            TorrentPid   = etorrent_torrent_ctl:lookup_server(Id),
            {ok, Valid}  = etorrent_torrent_ctl:valid_pieces(TorrentPid),
            Bitfield     = etorrent_pieceset:to_binary(Valid),
            {ok, Wishes} = etorrent_torrent_ctl:get_permanent_wishes(Id),
            [{state, State}
            ,{bitfield, Bitfield}
            ,{wishes, Wishes}
            ,{uploaded, Uploaded}
            ,{downloaded, Downloaded}]
    end.
