%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Handle various state about torrents in ETS tables.
%% <p>This module implements a server which governs 3 internal ETS
%% tables. As long as the process is living, the tables are there for
%% other processes to query. Also, the server acts as a serializer on
%% table access.</p>
%% @end
-module(etorrent_table).
-behaviour(gen_server).
-include("log.hrl").


%% API
%% Startup/init
-export([start_link/0]).

%% File Path map
-export([get_path/2, insert_path/2, delete_paths/1]).

%% Peer information
-export([
         all_peers/0,
         connected_peer/3,
	 foreach_peer/2, foreach_peer_of_tracker/2,
         get_peer_info/1,
         new_peer/6,
         statechange_peer/2
        ]).



%% UPnP entity information
-export([register_upnp_entity/3,
         lookup_upnp_entity/2,
         update_upnp_entity/3]).

%% Torrent information
-export([all_torrents/0,
         new_torrent/4,
         statechange_torrent/2,
         get_torrent/1,
	 acquire_check_token/1]).

%% Histogram handling code
-export([
         histogram_enter/2,
         histogram/1,
         histogram_delete/1]).


%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).


-type ipaddr() :: etorrent_types:ipaddr().
-type portnum() :: etorrent_types:portnum().
%% The path map tracks file system paths and maps them to integers.
-record(path_map, {id :: {'_' | '$1' | non_neg_integer(), '_'
			      | non_neg_integer()},
                   path :: string() | '_'}). % File system path -- work dir

-record(peer, {pid :: pid() | '_' | '$1', % We identify each peer with it's pid.
               tracker_url_hash :: integer() | '_', % Which tracker this peer comes from.
                                              % A tracker is identified by the hash of its url.
               ip :: ipaddr() | '_',  % Ip of peer in question
               port :: non_neg_integer() | '_', % Port of peer in question
               torrent_id :: non_neg_integer() | '_', % Torrent Id for peer
               state :: 'seeding' | 'leeching' | '_'}).

-type(tracking_map_state() :: 'started' | 'stopped' | 'checking' | 'awaiting' | 'duplicate').

%% The tracking map tracks torrent id's to filenames, etc. It is the
%% high-level view
-record(tracking_map, {id :: '_' | integer(), %% Unique identifier of torrent
                       filename :: '_' | string(),    %% The filename
                       supervisor_pid :: '_' | pid(), %% Who is supervising
                       info_hash :: '_' | binary() | 'unknown',
                       state :: '_' | tracking_map_state()}).

-record(state, { monitoring :: dict() }).

-ignore_xref([{start_link, 0}]).

-define(SERVER, ?MODULE).
-define(TAB_UPNP, upnp_entity).

%%====================================================================

%% @doc Start the server
%% @end
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Return everything we are currently tracking by their ids
%% @end
-spec all_torrents() -> [term()]. % @todo: Fix as proplists
all_torrents() ->
    Objs = ets:match_object(tracking_map, '_'),
    [proplistify_tmap(O) || O <- Objs].

%% @doc Return a status on all peers in the main table
%% @end
-spec all_peers() -> [proplist:proplist()].
all_peers() ->
    Objs = ets:match_object(peers, '_'),
    [proplistify_peers(O) || O <- Objs].

%% @doc Alter the state of the Tracking map identified by Id
%%   <p>by What (see alter_map/2).</p>
%% @end
-type alteration() :: {infohash, binary()} | started | stopped | checking.
-spec statechange_torrent(integer(), alteration()) -> ok.
statechange_torrent(Id, What) ->
    [O] = ets:lookup(tracking_map, Id),
    ets:insert(tracking_map, alter_map(O, What)),
    ok.

%% @doc Lookup a torrent by a Key
%% <p>Several keys are accepted: Infohash, filename, TorrentId. Return
%% is a proplist with information about the torrent.</p>
%% @end
-spec get_torrent({infohash, binary()} | {filename, string()} | integer()) ->
			  not_found | {value, term()}. % @todo: Change term() to proplist()
get_torrent(Id) when is_integer(Id) ->
    case ets:lookup(tracking_map, Id) of
	[O] ->
	    {value, proplistify_tmap(O)};
	[] ->
	    not_found
    end;
get_torrent({infohash, IH}) ->
    case ets:match_object(tracking_map, #tracking_map { _ = '_', info_hash = IH }) of
	[O] ->
	    {value, proplistify_tmap(O)};
	[] ->
	    not_found
    end;
get_torrent({filename, FN}) ->
    case ets:match_object(tracking_map, #tracking_map { _ = '_', filename = FN }) of
	[O] ->
	    {value, proplistify_tmap(O)};
	[] ->
	    not_found
    end.

%% @doc Enter a Piece Number in the histogram
%% @end
-spec histogram_enter(pid(), pos_integer()) -> true.
histogram_enter(Pid, PN) ->
    ets:insert_new(histogram, {Pid, PN}).

%% @doc Return the histogram part of the peer represented by Pid
%% @end
-spec histogram(pid()) -> [pos_integer()].
histogram(Pid) ->
    ets:lookup_element(histogram, Pid, 2).

%% @doc Delete the histogram for a Pid
%% @end
-spec histogram_delete(pid()) -> true.
histogram_delete(Pid) ->
    ets:delete(histogram, Pid).

% @doc Map a {PathId, TorrentId} pair to a Path (string()).
% @end
-spec get_path(integer(), integer()) -> {ok, string()}.
get_path(Id, TorrentId) when is_integer(Id) ->
    Pth = ets:lookup_element(path_map, {Id, TorrentId}, #path_map.path),
    {ok, Pth}.

%% @doc Attempt to mark the torrent for checking.
%%  <p>If this succeeds, returns true, else false</p>
%% @end
-spec acquire_check_token(integer()) -> boolean().
acquire_check_token(Id) ->
    %% @todo when using a monitor-approach, this can probably be
    %% infinity.
    gen_server:call(?MODULE, {acquire_check_token, Id}).

%% @doc Populate the #path_map table with entries. Return the Id
%% <p>If the path-map entry is already there, its Id is returned straight
%% away.</p>
%% @end
-spec insert_path(string(), integer()) -> {value, integer()}.
insert_path(Path, TorrentId) ->
    case ets:match(path_map, #path_map { id = {'$1', '_'}, path = Path}) of
        [] ->
            Id = etorrent_counters:next(path_map),
            PM = #path_map { id = {Id, TorrentId}, path = Path},
	    true = ets:insert(path_map, PM),
            {value, Id};
	[[Id]] ->
            {value, Id}
    end.

%% @doc Delete entries from the pathmap based on the TorrentId
%% @end
-spec delete_paths(integer()) -> ok.
delete_paths(TorrentId) when is_integer(TorrentId) ->
    MS = [{{path_map,{'_','$1'},'_','_'},[],[{'==','$1',TorrentId}]}],
    ets:select_delete(path_map, MS),
    ok.

%% @doc Find the peer matching Pid
%% @todo Consider coalescing calls to this function into the select-function
%% @end
-spec get_peer_info(pid()) -> not_found | {peer_info, seeding | leeching, integer()}.
get_peer_info(Pid) when is_pid(Pid) ->
    case ets:lookup(peers, Pid) of
	[] -> not_found;
	[PR] -> {peer_info, PR#peer.state, PR#peer.torrent_id}
    end.

%% @doc Return all peer pids with a given torrentId
%% @end
%% @todo We can probably fetch this from the supervisor tree. There is
%% less reason to have this then.
-spec all_peer_pids(integer()) -> {value, [pid()]}.
all_peer_pids(Id) ->
    R = ets:match(peers, #peer { torrent_id = Id, pid = '$1', _ = '_' }),
    {value, [Pid || [Pid] <- R]}.

%% @doc Return all peer pids come from the tracker designated by its url.
%% @end
-spec all_peers_of_tracker(string()) -> {value, [pid()]}.
all_peers_of_tracker(Url) ->
    R = ets:match(peers, #peer{tracker_url_hash = erlang:phash2(Url),
                               pid = '$1', _ = '_'}),
    {value, [Pid || [Pid] <- R]}.

%% @doc Change the peer to a seeder
%% @end
-spec statechange_peer(pid(), seeder) -> ok.
statechange_peer(Pid, seeder) ->
    [Peer] = ets:lookup(peers, Pid),
    true = ets:insert(peers, Peer#peer { state = seeding }),
    ok.

%% @doc Insert a row for the peer
%% @end
-spec new_peer(string(), ipaddr(), portnum(), integer(), pid(), seeding | leeching) -> ok.
new_peer(TrackerUrl, IP, Port, TorrentId, Pid, State) ->
    true = ets:insert(peers, #peer { pid = Pid, tracker_url_hash = erlang:phash2(TrackerUrl),
                     ip = IP, port = Port, torrent_id = TorrentId, state = State}),
    add_monitor(peer, Pid).

%% @doc Add a new torrent
%% <p>The torrent is given by File and its infohash with the
%% Supervisor pid as given to the database structure.</p>
%% @end
-spec new_torrent(string(), binary(), pid(), integer()) -> ok.
new_torrent(File, IH, Supervisor, Id) when is_integer(Id),
                                        is_pid(Supervisor),
                                        is_binary(IH),
                                        is_list(File) ->
    add_monitor({torrent, Id}, Supervisor),
    TM = #tracking_map { id = Id,
			 filename = File,
			 supervisor_pid = Supervisor,
			 info_hash = IH,
			 state = awaiting},
    true = ets:insert(tracking_map, TM),
    ok.

%% @doc Returns true if we are already connected to this peer.
%% @end
-spec connected_peer(ipaddr(), portnum(), integer()) -> boolean().
connected_peer(IP, Port, Id) when is_integer(Id) ->
    case ets:match(peers, #peer { ip = IP, port = Port, torrent_id = Id, _ = '_'}) of
	[] -> false;
	L when is_list(L) -> true
    end.

%% @doc Invoke a function on all peers matching a torrent Id
%% @end
-spec foreach_peer(integer(), fun((pid()) -> term())) -> ok.
foreach_peer(Id, F) ->
    {value, Pids} = all_peer_pids(Id),
    lists:foreach(F, Pids),
    ok.

%% @doc Invoke a function on all peers come from one tracker.
%% @end
-spec foreach_peer_of_tracker(string(), fun((pid()) -> term())) -> ok.
foreach_peer_of_tracker(TrackerUrl, F) ->
    {value, Pids} = all_peers_of_tracker(TrackerUrl),
    lists:foreach(F, Pids),
    ok.


%% @doc Inserts a UPnP entity into its dedicated ETS table.
%% @end
-spec register_upnp_entity(pid(), device | service,
                           etorrent_types:upnp_device() |
                           etorrent_types:upnp_service()) -> true.
register_upnp_entity(Pid, Cat, Entity) ->
    Id = etorrent_upnp_entity:id(Cat, Entity),
    add_monitor({upnp, Cat, Entity}, Pid),
    true = ets:insert(?TAB_UPNP, {Id, Pid, Cat, Entity}).

%% @doc Returns the pid that governs given UPnP entity.
%% @end
-spec lookup_upnp_entity(device | service,
                         etorrent_types:upnp_device() |
                         etorrent_types:upnp_service()) ->
                                {ok, pid()} | {error, not_found}.
lookup_upnp_entity(Cat, Entity) ->
    case ets:lookup(?TAB_UPNP, etorrent_upnp_entity:id(Cat, Entity)) of
        [{_Id, Pid, _Cat, _Entity}] -> {ok, Pid};
        [] -> {error, not_found}
    end.

%% @doc Updates UPnP ETS table with information of given UPnP entity.
%% @end
-spec update_upnp_entity(pid(), device | service,
                         etorrent_types:upnp_device() |
                         etorrent_types:upnp_service()) -> true.
update_upnp_entity(Pid, Cat, Entity) ->
    EntityId = etorrent_upnp_entity:id(Cat, Entity),
    true = ets:insert(?TAB_UPNP, {EntityId, Pid, Cat, Entity}).

%%====================================================================

%% @private
init([]) ->
    ets:new(path_map, [public, {keypos, #path_map.id}, named_table]),
    ets:new(peers, [named_table, {keypos, #peer.pid}, public]),
    ets:new(tracking_map, [named_table, {keypos, #tracking_map.id}, public]),
    ets:new(histogram, [named_table, {keypos, 1}, public, bag]),
    {ok, #state{ monitoring = dict:new() }}.

%% @private
handle_call({monitor_pid, Type, Pid}, _From, S) ->
    Ref = erlang:monitor(process, Pid),
    {reply, ok,
     S#state {
       monitoring = dict:store(Ref, {Pid, Type}, S#state.monitoring)}};
handle_call({acquire_check_token, Id}, _From, S) ->
    %% @todo This should definitely be a monitor on the _From process
    R = case ets:match(tracking_map, #tracking_map { _ = '_', state = checking }) of
	    [] ->
		[O] = ets:lookup(tracking_map, Id),
		ets:insert(tracking_map, O#tracking_map { state = checking }),
		true;
	    _ ->
		false
	end,
    {reply, R, S};
handle_call(Msg, _From, S) ->
    ?WARN([unknown_msg, Msg]),
    {noreply, S}.

%% @private
handle_cast(Msg, S) ->
    ?WARN([unknown_msg, Msg]),
    {noreply, S}.

%% @private
handle_info({'DOWN', Ref, _, _, _}, S) ->
    {ok, {X, Type}} = dict:find(Ref, S#state.monitoring),
    case Type of
	peer ->
	    true = ets:delete(peers, X);
	{torrent, Id} ->
	    true = ets:delete(tracking_map, Id);
    {upnp, Cat, Entity} ->
        EntityId = etorrent_upnp_entity:id(Cat, Entity),
        etorrent_upnp_entity:unsubscribe(Cat, Entity),
        true = ets:delete(?TAB_UPNP, EntityId)
    end,
    {noreply, S#state { monitoring = dict:erase(Ref, S#state.monitoring) }};
handle_info(Msg, S) ->
    ?WARN([unknown_msg, Msg]),
    {noreply, S}.

%% @private
code_change(_OldVsn, S, _Extra) ->
    {ok, S}.

%% @private
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------

proplistify_tmap(#tracking_map { id = Id, filename = FN, supervisor_pid = SPid,
				 info_hash = IH, state = S }) ->
    [proplists:property(K,V) || {K, V} <- [{id, Id}, {filename, FN}, {supervisor, SPid},
					   {info_hash, IH}, {state, S}]].

proplistify_peers(#peer {
                     pid = Pid, ip = IP, port = Port,
                     torrent_id = TorrentId, state = State
                    }) ->
    [proplists:property(K, V) || {K, V} <- [{pid, Pid}, {ip, IP}, {port, Port},
                                            {torrent_id, TorrentId},
                                            {state, State}]].

add_monitor(Type, Pid) ->
    gen_server:call(?SERVER, {monitor_pid, Type, Pid}).

alter_map(TM, What) ->
    case What of
        {infohash, IH} ->
            TM#tracking_map { info_hash = IH };
	checking ->
	    TM#tracking_map { state = checking };
        started ->
            TM#tracking_map { state = started };
        stopped ->
            TM#tracking_map { state = stopped }
    end.
