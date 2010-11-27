%%%-------------------------------------------------------------------
%%% File    : tracker_delegate.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% License : See COPYING
%%% Description : Handles communication with the tracker
%%%
%%% Created : 17 Jul 2007 by Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
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

%% Dummy exports
-export([swap_urls/1]).

-record(state, {queued_message = none,
                %% The hard timer is the time we *must* wait on the tracker.
                %% soft timer may be overridden if we want to change state.
                soft_timer = none,
                hard_timer = none,
                url = none,
                info_hash = none,
                peer_id = none,
                trackerid = none,
                control_pid = none,
                torrent_id = none}).

-type tier() :: [string()].


-define(DEFAULT_CONNECTION_TIMEOUT_INTERVAL, 1800).
-define(DEFAULT_CONNECTION_TIMEOUT_MIN_INTERVAL, 60).
-define(DEFAULT_TRACKER_OVERLOAD_INTERVAL, 300).
-define(DEFAULT_REQUEST_TIMEOUT, 240).
%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
-spec start_link(pid(), [tier()], binary(), integer(), integer()) ->
    ignore | {ok, pid()} | {error, any()}.
start_link(ControlPid, UrlTiers, InfoHash, PeerId, TorrentId) ->
    gen_server:start_link(?MODULE,
                          [ControlPid,
                            UrlTiers, InfoHash, PeerId, TorrentId],
                          []).

-spec completed(pid()) -> ok.
completed(Pid) ->
    gen_server:cast(Pid, completed).

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
init([ControlPid, UrlTiers, InfoHash, PeerId, TorrentId]) ->
    process_flag(trap_exit, true),
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

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%---------------------------------------------------------------------
handle_cast(completed, S) ->
    NS = contact_tracker(completed, S),
    {noreply, NS};
handle_cast(Msg, #state { hard_timer = none } = S) ->
    NS = contact_tracker(Msg, S),
    {noreply, NS};
handle_cast(Msg, S) ->
    ?ERR([unknown_msg, Msg]),
    {noreply, S}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
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

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
%% XXX: Cancel timers for completeness.
terminate(_Reason, S) ->
    _NS = contact_tracker(stopped, S),
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

-spec contact_tracker(#state{}) ->
			     #state{}.
contact_tracker(S) ->
    contact_tracker(none, S).

-spec contact_tracker(tracker_event() | none, #state{}) ->
			     #state{}.
contact_tracker(Event, #state { url = Tiers } = S) ->
    case contact_tracker(Tiers, Event, S) of
	{none, NS} ->
	    NS;
	{ok, NS} ->
	    NS
    end.

-spec contact_tracker([[string()]], term(), #state{}) ->
			      {none, #state{}} | {ok, #state{}}.
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

-spec contact_tracker_tier([string()], #state{}, term) -> {ok, #state{}} | none.
contact_tracker_tier(Tier, S, Event) ->
    contact_tracker_tier(Tier, S, Event, []).

contact_tracker_tier([], _Event, _S, _Acc) ->
    none;
contact_tracker_tier([Url | Next], Event, S, Acc) ->
    case
	case identify_url_type(Url) of
	    http -> contact_tracker_http(Url, Event, S);
	    {udp, IP, Port}  -> contact_tracker_udp(IP, Port, Event, S)
	end
    of
	{ok, NS} ->
	    {ok, NS, [Url] ++ lists:reverse(Acc) ++ Next};
	error ->
	    contact_tracker_tier(Next, Event, S, [Url | Acc])
    end.

-spec identify_url_type(string()) -> http | {udp, string(), integer()}.
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


contact_tracker_udp(IP, Port, Event, #state { torrent_id = Id,
					      info_hash = InfoHash,
					      peer_id = PeerId } = S) ->
    {torrent_info, Uploaded, Downloaded, Left} = % Change this to a proplist
	etorrent_torrent:find(Id),
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
	    {I, MI} = handle_udp_response(Id, Peers, Status),
	    {ok, handle_timeout(I, MI, S)};
	timeout ->
	    error
    end.

%% @todo: consider not passing around the state here!
contact_tracker_http(Url, Event, S) ->
    RequestUrl = build_tracker_url(Url, Event, S),
    case http_gzip:request(RequestUrl) of
        {ok, {{_, 200, _}, _, Body}} ->
	    {ok,
	     handle_tracker_response(etorrent_bcoding:decode(Body), S)};
        {error, Type} ->
	    case Type of
		etimedout -> ignore;
		econnrefused -> ignore;
		session_remotly_closed -> ignore;
		Err ->
		    error_logger:error_report([contact_tracker_error, Err]),
		    ignore
	    end,
	    error
    end.

-spec handle_tracker_response(bcode(), #state{}) -> #state{}.
handle_tracker_response(BC, S) ->
    handle_tracker_response(BC,
			    get_string("failure reason", BC),
			    get_string("warning message", BC),
                            S).

get_string(What, BC) ->
    case etorrent_bcoding:get_value(What, BC) of
	undefined -> none;
	B when is_binary(B) -> binary_to_list(B)
    end.


handle_tracker_response(BC, E, _WM, S) when is_binary(E) ->
    etorrent_t_control:tracker_error_report(S#state.control_pid, E),
    handle_timeout(BC, S);
handle_tracker_response(BC, none, W, S) when is_binary(W) ->
    etorrent_t_control:tracker_warning_report(S#state.control_pid, W),
    handle_tracker_response(BC, none, none, S);
handle_tracker_response(BC, none, none, S) ->
    %% Add new peers
    etorrent_peer_mgr:add_peers(S#state.torrent_id,
                                response_ips(BC)),
    %% Update the state of the torrent
    ok = etorrent_torrent:statechange(
	   S#state.torrent_id,
	   [{tracker_report,
	     etorrent_bcoding:get_value("complete", BC, 0),
	     etorrent_bcoding:get_value("incomplete", BC, 0)}]),
    %% Timeout
    TrackerId = etorrent_bcoding:get_value("trackerid", BC, tracker_id_not_given),
    handle_timeout(BC, S#state { trackerid = TrackerId }).

handle_udp_response(Id, Peers, Status) ->
    etorrent_peer_mgr:add_peers(Id, Peers),
    etorrent_torrent:statechange(Id,
				 [{tracker_report,
				   proplists:get_value(seeders, Status, 0),
				   proplists:get_value(leechers, Status, 0)}]),
    {proplists:get_value(interval, Status), ?DEFAULT_CONNECTION_TIMEOUT_MIN_INTERVAL}.

-spec handle_timeout(#state{}) -> #state{}.
handle_timeout(S) ->
    Interval = ?DEFAULT_CONNECTION_TIMEOUT_INTERVAL,
    MinInterval = ?DEFAULT_CONNECTION_TIMEOUT_MIN_INTERVAL,
    handle_timeout(Interval, MinInterval, S).

-spec handle_timeout(bcode(), #state{}) ->
			    #state{}.
handle_timeout(BC, S) ->
    Interval = etorrent_bcoding:get_value("interval", BC, ?DEFAULT_REQUEST_TIMEOUT),
    MinInterval = etorrent_bcoding:get_value("min interval", BC, none),
    handle_timeout(Interval, MinInterval, S).

handle_timeout(Interval, MinInterval, S) ->
    NS = cancel_timers(S),
    NNS = case MinInterval of
              none ->
                  NS;
              I when is_integer(I) ->
                  TRef = erlang:send_after(timer:seconds(I), self(), hard_timeout),
                  NS#state { hard_timer = TRef }
          end,
    TRef2 = erlang:send_after(timer:seconds(Interval), self(), soft_timeout),
    NNS#state { soft_timer = TRef2 }.

cancel_timers(S) ->
    NS = case S#state.hard_timer of
             none -> S;
             TRef ->
                 erlang:cancel_timer(TRef),
                 S#state { hard_timer = none }
         end,
    case NS#state.soft_timer of
        none ->
            NS;
        TRef2 ->
            erlang:cancel_timer(TRef2),
            NS#state { soft_timer = none }
    end.

build_tracker_url(Url, Event,
		  #state { torrent_id = Id,
			   info_hash = InfoHash,
			   peer_id = PeerId }) ->
    {torrent_info, Uploaded, Downloaded, Left} =
                etorrent_torrent:find(Id),
    {ok, Port} = application:get_env(etorrent, port),
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
    {[length(T) || T <- L], lists:concat(L)}.

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
