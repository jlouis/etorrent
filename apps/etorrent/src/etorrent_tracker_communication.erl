%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Handle communication with trackers
%% <p>This module handles all communication with a tracker. It will
%% periodically announce to the tracker for an update. Eventual errors
%% and new Peers are fed back into the Peer Manager process so they
%% can be processed to completion.</p>
%% <p>For UDP tracking, we delegate the work to the UDP tracker
%% system.</p>
%% @end
-module(etorrent_tracker_communication).

-behaviour(gen_server).
-include("log.hrl").
-include("types.hrl").

-ifdef(TEST).
-include_lib("eqc/include/eqc.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([start_link/5, completed/1]).
-ignore_xref([{'start_link', 5}]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {queued_message = none :: none | started,
                %% The hard timer is the time we *must* wait on the tracker.
                %% soft timer may be overridden if we want to change state.
                soft_timer     :: reference() | none,
                hard_timer     :: reference() | none,
                url = [[]]     :: [tier()],
                info_hash      :: binary(),
                peer_id        :: string(),
                control_pid    :: pid(),
                torrent_id     :: integer() }).

-define(DEFAULT_CONNECTION_TIMEOUT_INTERVAL, 1800).
-define(DEFAULT_CONNECTION_TIMEOUT_MIN_INTERVAL, 60).
-define(DEFAULT_TRACKER_OVERLOAD_INTERVAL, 300).
-define(DEFAULT_REQUEST_TIMEOUT, 240).
%%====================================================================

%% @doc Start the server
%% <p>Start the server. We are given a large amount of
%% information. The `ControlPid' refers to the Pid of the controller
%% process. The `UrlTiers' are a list of lists of string() parameters,
%% each a URL. Next comes the `Infohash' as a binary(), the `PeerId'
%% parameter and finally the `TorrentId': the identifier of the torrent.</p> 
%% @end
%% @todo What module, precisely do the control pid come from?
-spec start_link(pid(), [tier()], binary(), string(), integer()) ->
    ignore | {ok, pid()} | {error, term()}.
start_link(ControlPid, UrlTiers, InfoHash, PeerId, TorrentId) ->
    gen_server:start_link(?MODULE,
                          [ControlPid,
                            UrlTiers, InfoHash, PeerId, TorrentId],
                          []).

%% @doc Prod the tracker and tell it we completed to torrent
%% @end
-spec completed(pid()) -> ok.
completed(Pid) ->
    gen_server:cast(Pid, completed).

%%====================================================================

%% @private
init([ControlPid, UrlTiers, InfoHash, PeerId, TorrentId]) ->
    process_flag(trap_exit, true),
    random:seed(now()),
    HardRef = erlang:send_after(0, self(), hard_timeout),
    SoftRef = erlang:send_after(timer:seconds(?DEFAULT_CONNECTION_TIMEOUT_INTERVAL),
			       self(),
			       soft_timeout),
    Url = swap_urls(shuffle_tiers(UrlTiers)),
    {ok, #state{control_pid = ControlPid,
                torrent_id = TorrentId,
                url = Url,
                info_hash = InfoHash,
                peer_id = PeerId,

                soft_timer = SoftRef,
                hard_timer = HardRef,

                queued_message = started}}.

%% @private
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%% @private
handle_cast(completed, S) ->
    NS = contact_tracker(completed, S),
    {noreply, NS};
handle_cast(Msg, #state { hard_timer = none } = S) ->
    NS = contact_tracker(Msg, S),
    {noreply, NS};
handle_cast(Msg, S) ->
    ?ERR([unknown_msg, Msg]),
    {noreply, S}.

%% @private
handle_info(hard_timeout,
    #state { queued_message = none } = S) ->
    %% There is nothing to do with the hard_timer, just ignore this
    {noreply, S#state { hard_timer = none }};
handle_info(hard_timeout, S) ->
    NS = contact_tracker(S#state.queued_message, S),
    {noreply, NS#state { queued_message = none}};
handle_info(soft_timeout, S) ->
    %% Soft timeout
    NS = contact_tracker(S),
    {noreply, NS};
handle_info({Ref, _M}, State) when is_reference(Ref) ->
    %% Quench late messages arriving
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(Reason, S) when Reason =:= shutdown; Reason =:= normal ->
    _NS = contact_tracker(stopped, S),
    ok;
terminate(Reason, _S) ->
    ?WARN([terminating_due_to, Reason]),
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
contact_tracker(S) ->
    contact_tracker(none, S).

contact_tracker(Event, #state { url = Tiers } = S) ->
    case contact_tracker(Tiers, Event, S) of
	{none, NS} ->
	    NS;
	{ok, NS} ->
	    NS
    end.

contact_tracker(Tiers, Event, S) ->
    contact_tracker(Tiers, Event, S, []).

contact_tracker([], _Event, S, _Acc) ->
    {none, handle_timeout(S)};
contact_tracker([Tier | NextTier], Event, S, Acc) ->
    case contact_tracker_tier(Tier, Event, S) of
	{ok, NS, NewTier} ->
	    {ok, NS#state { url = lists:reverse(Acc) ++ [NewTier | NextTier] }};
	none ->
	    contact_tracker(NextTier, Event, S, [Tier | Acc])
    end.

contact_tracker_tier(Tier, S, Event) ->
    contact_tracker_tier(Tier, S, Event, []).

contact_tracker_tier([], _Event, _S, _Acc) ->
    none;
contact_tracker_tier([Url | Next], Event, S, Acc) ->
    case
	case identify_url_type(Url) of
	    http -> contact_tracker_http(Url, Event, S);
	    {udp, IP, Port}  -> contact_tracker_udp(Url, IP, Port, Event, S)
	end
    of
	{ok, NS} ->
	    {ok, NS, [Url] ++ lists:reverse(Acc) ++ Next};
	error ->
	    %% For private torrent (BEP 27), disconnect all peers coming
	    %% from the tracker before switching to another one
	    case etorrent_torrent:is_private(S#state.torrent_id) of
	        true -> disconnect_tracker(Url)
	    end,
	    contact_tracker_tier(Next, Event, S, [Url | Acc])
    end.

identify_url_type(Url) ->
    case etorrent_http_uri:parse(Url) of
	{S1, _UserInfo, Host, Port, _Path, _Query} ->
	    case S1 of
		http ->
		    http;
		udp ->
		    {udp, Host, Port}
	    end;
	{error, Reason} ->
	    ?WARN([Reason, Url]),
	    exit(identify_url_type)

    end.

%% @doc Disconnect from tracker designated by its url.
%% <p>It is called to comply with BEP 27 Private Torrents,
%% which reads: "When switching between trackers,
%% the peer MUST disconnect from all current peers".</p>
%% @end
-spec disconnect_tracker(string()) -> ok.
disconnect_tracker(Url) ->
    F = fun(P) ->
        etorrent_peer_control:stop(P)
    end,
    etorrent_table:foreach_peer_of_tracker(Url, F),
    ok.

contact_tracker_udp(Url, IP, Port, Event,
                        #state { torrent_id = Id,
                                info_hash = InfoHash,
                                peer_id = PeerId } = S) ->
    {value, PL} = etorrent_torrent:lookup(Id),
    Uploaded   = proplists:get_value(uploaded, PL),
    Downloaded = proplists:get_value(downloaded, PL),
    Left       = proplists:get_value(left, PL),
    PropList = [{info_hash, InfoHash},
		{peer_id, list_to_binary(PeerId)},
		{up, Uploaded},
		{down, Downloaded},
		{left, Left},
		{port, Port},
		{key, 0}, %% @todo: Actually process the key correctly for private tracking
		{event, Event}],
    ?INFO([announcing_via_udp]),
    case etorrent_udp_tracker_mgr:announce({IP, Port}, PropList, timer:seconds(60)) of
	{ok, {announce, Peers, Status}} ->
	    ?INFO([udp_reply_handled]),
	    {I, MI} = handle_udp_response(Url, Id, Peers, Status),
	    {ok, handle_timeout(I, MI, S)};
	timeout ->
	    error
    end.

%% @todo: consider not passing around the state here!
contact_tracker_http(Url, Event, S) ->
    RequestUrl = build_tracker_url(Url, Event, S),
    case etorrent_http:request(RequestUrl) of
    {ok, {{_, 200, _}, _, Body}} ->
        case etorrent_bcoding:decode(Body) of
        {ok, BC} -> {ok, handle_tracker_response(Url, BC, S)};
        {error, _} ->
            etorrent_event:notify({malformed_tracker_response, Body}),
            error
        end;
    {error, Type} ->
	    case Type of
		etimedout -> ignore;
		econnrefused -> ignore;
		session_remotly_closed -> ignore;
		Err ->
		    Msg = {error, [{contact_tracker, Err},
				   {id, S#state.torrent_id}]},
		    etorrent_event:notify(Msg),
		    ?INFO([Msg]),
		    ignore
	    end,
	    error
    end.

handle_tracker_response(Url, BC, S) ->
    case etorrent_bcoding:get_string_value("failure reason", BC, none) of
	none ->
	    report_warning(
	      S#state.torrent_id,
	      etorrent_bcoding:get_string_value("warning message", BC, none)),
	    handle_tracker_bcoding(Url, BC, S);
	Err ->
	    etorrent_event:notify({tracker_error, S#state.torrent_id, Err}),
	    handle_timeout(BC, S)
    end.

report_warning(_Id, none) -> ok;
report_warning(Id, Warn) ->
    etorrent_event:notify({tracker_warning, Id, Warn}).

handle_tracker_bcoding(Url, BC, S) ->
    %% Add new peers
    etorrent_peer_mgr:add_peers(Url,
                                S#state.torrent_id,
                                response_ips(BC)),
    %% Update the state of the torrent
    ok = etorrent_torrent:statechange(
	   S#state.torrent_id,
	   [{tracker_report,
	     etorrent_bcoding:get_value("complete", BC, 0),
	     etorrent_bcoding:get_value("incomplete", BC, 0)}]),
    %% Timeout
    handle_timeout(BC, S).

handle_udp_response(Url, Id, Peers, Status) ->
    etorrent_peer_mgr:add_peers(Url, Id, Peers),
    etorrent_torrent:statechange(Id,
				 [{tracker_report,
				   proplists:get_value(seeders, Status, 0),
				   proplists:get_value(leechers, Status, 0)}]),
    {proplists:get_value(interval, Status), ?DEFAULT_CONNECTION_TIMEOUT_MIN_INTERVAL}.

handle_timeout(S) ->
    Interval = ?DEFAULT_CONNECTION_TIMEOUT_INTERVAL,
    MinInterval = ?DEFAULT_CONNECTION_TIMEOUT_MIN_INTERVAL,
    handle_timeout(Interval, MinInterval, S).

handle_timeout(BC, S) ->
    Interval = etorrent_bcoding:get_value("interval", BC, ?DEFAULT_REQUEST_TIMEOUT),
    MinInterval = etorrent_bcoding:get_value("min interval", BC, none),
    handle_timeout(Interval, MinInterval, S).

handle_timeout(Interval, MinInterval, S) ->
    cancel_timer(S#state.hard_timer),
    cancel_timer(S#state.soft_timer),
    TRef2 = erlang:send_after(timer:seconds(Interval), self(), soft_timeout),
    S#state { soft_timer = TRef2,
              hard_timer = handle_min_interval(MinInterval) }.

handle_min_interval(none) -> none;
handle_min_interval(I) when is_integer(I) ->
    erlang:send_after(timer:seconds(I), self(), hard_timeout).

cancel_timer(none) -> ok;
cancel_timer(TRef) -> erlang:cancel_timer(TRef).

build_tracker_url(Url, Event,
		  #state { torrent_id = Id,
			   info_hash = InfoHash,
			   peer_id = PeerId }) ->
    {value, PL} = etorrent_torrent:lookup(Id),
    Uploaded   = proplists:get_value(uploaded, PL),
    Downloaded = proplists:get_value(downloaded, PL),
    Left       = proplists:get_value(left, PL),
    Port = etorrent_config:listen_port(),
    Request = [{"info_hash",
                etorrent_http:build_encoded_form_rfc1738(InfoHash)},
               {"peer_id",
                etorrent_http:build_encoded_form_rfc1738(PeerId)},
               {"uploaded", Uploaded},
               {"downloaded", Downloaded},
               {"left", Left},
               {"port", Port},
               {"compact", 1}],
    EReq = case Event of
               none -> Request;
               started -> [{"event", "started"} | Request];
               stopped -> [{"event", "stopped"} | Request];
               completed -> [{"event", "completed"} | Request]
           end,
    lists:concat([Url, "?", etorrent_http:mk_header(EReq)]).

%%% Tracker response lookup functions
response_ips(BC) ->
    case etorrent_bcoding:get_value("peers", BC, none) of
	none -> [];
	IPs  -> etorrent_utils:decode_ips(IPs)
    end.


%%% BEP 12 stuff
%%% ----------------------------------------------------------------------
shuffle_tiers(Tiers) ->
    [etorrent_utils:list_shuffle(T) || T <- Tiers].

splice(L) ->
    {[length(T) || T <- L], lists:append(L)}.

unsplice([], []) -> [];
unsplice([K | KR], List) ->
    {F, R} = lists:split(K, List),
    [F | unsplice(KR, R)].

swap_urls(Tiers) ->
    {Breaks, CL} = splice(Tiers),
    NCL = swap(CL),
    unsplice(Breaks, NCL).

swap([]) -> [];
swap([Url | R]) ->
    {H, T} = swap_in_tier(Url, R, []),
    [H | swap(T)].

swap_in_tier(Url, [], Acc) -> {Url, lists:reverse(Acc)};
swap_in_tier(Url, [H | T], Acc) ->
    case should_swap_for(Url, H) of
	true ->
	    {H, lists:reverse(Acc) ++ [Url | T]};
	false ->
	    swap_in_tier(Url, T, [H | Acc])
    end.

should_swap_for(Url1, Url2) ->
    {S1, _UserInfo, Host1, _Port, _Path, _Query} = etorrent_http_uri:parse(Url1),
    {_S2, _, Host2, _, _, _} = etorrent_http_uri:parse(Url2),
    Host1 == Host2 andalso S1 == http.

%%% Test
%%% ----------------------------------------------------------------------
-ifdef(EUNIT).

tier() ->
    [["http://one.com", "http://two.com", "udp://one.com"],
     ["udp://four.com", "udp://two.com", "http://three.com"]].

splice_test() ->
    {L, Concat} = splice(tier()),
    ?assertEqual({[3,3], lists:concat(tier())}, {L, Concat}).

swap_test() ->
    Swapped = swap(lists:concat(tier())),
    ?assertEqual(["udp://one.com", "udp://two.com", "http://one.com",
		  "udp://four.com", "http://two.com", "http://three.com"],
		 Swapped).

swap_urls_test() ->
    Swapped = swap_urls(tier()),
    ?assertEqual([["udp://one.com", "udp://two.com", "http://one.com"],
		  ["udp://four.com", "http://two.com", "http://three.com"]],
		 Swapped).

should_swap_test() ->
    ?assertEqual(true, should_swap_for("http://foo.com", "udp://foo.com")),
    ?assertEqual(false, should_swap_for("http://foo.com", "udp://bar.com")),
    ?assertEqual(true, should_swap_for("http://foo.com", "udp://foo.com/something/more")).

-ifdef(EQC).

scheme() -> oneof([http, udp]).

host() -> oneof(["one.com", "two.com", "three.com", "four.com", "five.com"]).

url() ->
    ?LET({Scheme, Host}, {scheme(), host()},
	 atom_to_list(Scheme) ++ "://" ++ Host).

g_tier() -> list(url()).
g_tiers() -> list(g_tier()).

prop_splice_unsplice_inv() ->
    ?FORALL(In, g_tiers(),
	    begin
		{K, Spliced} = splice(In),
		In =:= unsplice(K, Spliced)
	    end).

eqc_test() ->
    ?assert(eqc:quickcheck(prop_splice_unsplice_inv())).

-endif.
-endif.
