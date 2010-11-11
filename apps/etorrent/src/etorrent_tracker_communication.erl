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
%% API
-export([start_link/5, completed/1]).
-ignore_xref([{'start_link', 5}]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

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

-define(DEFAULT_REQUEST_TIMEOUT, 180).
-define(DEFAULT_CONNECTION_TIMEOUT_INTERVAL, 1800).
-define(DEFAULT_CONNECTION_TIMEOUT_MIN_INTERVAL, 60).
-define(DEFAULT_TRACKER_OVERLOAD_INTERVAL, 300).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
-spec start_link(pid(), string(), binary(), integer(), integer()) ->
    ignore | {ok, pid()} | {error, any()}.
start_link(ControlPid, UrlTiers, InfoHash, PeerId, TorrentId) ->
    gen_server:start_link(?MODULE,
                          [ControlPid,
                            UrlTiers, InfoHash, PeerId, TorrentId],
                          []).

-spec completed(pid()) ->
		        ok.
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
    {ok, #state{control_pid = ControlPid,
                torrent_id = TorrentId,
                url = shuffle_tiers(UrlTiers),
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
	{ok, NS, NewTiers} ->
	    NS #state { url = NewTiers }
    end.
-type tier() :: [string()].
-spec contact_tracker([tier()], tracker_event() | none, #state{}) ->
			     {none, #state{}} | {ok, #state{}, [tier()]}.
contact_tracker([], _Event, #state { torrent_id = Id} = S) ->
    ?INFO([no_trackers_could_be_contacted, Id]),
    {none, handle_timeout(S)};
contact_tracker([Tier | NextTier], Event, S) ->
    case contact_tracker_tier(Tier, Event, S) of
	{ok, NS, MoveToFrontUrl, Rest} ->
	    NewTier = [MoveToFrontUrl | Rest],
	    {ok, NS, [NewTier | NextTier]};
	none ->
	    case contact_tracker(NextTier, Event, S) of
		{ok, NS, TierUrls} ->
		    {ok, NS, [Tier | TierUrls]};
		{none, NS} ->
		    {none, NS}
	    end
    end.

-spec contact_tracker_tier([string()], tracker_event() | none, #state{}) ->
				  none | {ok, #state{}, string(), [string()]}.
contact_tracker_tier([], _Event, _S) ->
    none;
contact_tracker_tier([Url | Next], Event, S) ->
    RequestUrl = build_tracker_url(Url, Event, S),
    ?INFO([{contacting_tracker, RequestUrl}]),
    case http_gzip:request(RequestUrl) of
        {ok, {{_, 200, _}, _, Body}} ->
	    {ok,
	     handle_tracker_response(etorrent_bcoding:decode(Body), S),
	     Url, Next};
        {error, Type} ->
	    case Type of
		etimedout -> ignore;
		econnrefused -> ignore;
		session_remotly_closed -> ignore;
		Err ->
		    error_logger:error_report([contact_tracker_error, Err]),
		    ignore
	    end,
	    case contact_tracker_tier(Next, Event, S) of
		{ok, NS, MoveToFrontUrl, Rest} ->
		    {ok, NS, MoveToFrontUrl, [Url | Rest]};
		none -> none
	    end
    end.

-spec handle_tracker_response(bcode(), #state{}) -> #state{}.
handle_tracker_response(BC, S) ->
    handle_tracker_response(BC,
                            fetch_error_message(BC),
                            fetch_warning_message(BC),
                            S).

handle_tracker_response(BC, {string, E}, _WM, S) ->
    etorrent_t_control:tracker_error_report(S#state.control_pid, E),
    handle_timeout(BC, S);
handle_tracker_response(BC, none, {string, W}, S) ->
    etorrent_t_control:tracker_warning_report(S#state.control_pid, W),
    handle_tracker_response(BC, none, none, S);
handle_tracker_response(BC, none, none, S) ->
    %% Add new peers
    etorrent_peer_mgr:add_peers(S#state.torrent_id,
                                response_ips(BC)),
    %% Update the state of the torrent
    ok = etorrent_torrent:statechange(S#state.torrent_id,
                                      [{tracker_report,
                                       decode_integer("complete", BC),
                                       decode_integer("incomplete", BC)}]),
    %% Timeout
    TrackerId = tracker_id(BC),
    handle_timeout(BC, S#state { trackerid = TrackerId }).

-spec handle_timeout(#state{}) -> #state{}.
handle_timeout(S) ->
    Interval = timer:seconds(?DEFAULT_CONNECTION_TIMEOUT_INTERVAL),
    MinInterval = timer:seconds(?DEFAULT_CONNECTION_TIMEOUT_MIN_INTERVAL),
    handle_timeout(Interval, MinInterval, S).

-spec handle_timeout(bcode(), #state{}) ->
			    #state{}.
handle_timeout(BC, S) ->
    Interval = response_interval(BC),
    MinInterval = response_mininterval(BC),
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


construct_headers([], HeaderLines) ->
    lists:concat(lists:reverse(HeaderLines));
construct_headers([{Key, Value}], HeaderLines) ->
    Data = lists:concat([Key, "=", Value]),
    construct_headers([], [Data | HeaderLines]);
construct_headers([{Key, Value} | Rest], HeaderLines) ->
    Data = lists:concat([Key, "=", Value, "&"]),
    construct_headers(Rest, [Data | HeaderLines]).

build_tracker_url(Url, Event,
		  #state { torrent_id = Id,
			   info_hash = InfoHash,
			   peer_id = PeerId }) ->
    {torrent_info, Uploaded, Downloaded, Left} =
                etorrent_torrent:find(Id),
    {ok, Port} = application:get_env(etorrent, port),
    Request = [{"info_hash",
                etorrent_utils:build_encoded_form_rfc1738(InfoHash)},
               {"peer_id",
                etorrent_utils:build_encoded_form_rfc1738(PeerId)},
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
    lists:concat([Url, "?", construct_headers(EReq, [])]).

%%% Tracker response lookup functions
response_interval(BC) ->
    {integer, R} = etorrent_bcoding:search_dict_default({string, "interval"},
                                                  BC,
                                                  {integer,
                                                   ?DEFAULT_REQUEST_TIMEOUT}),
    R.

response_mininterval(BC) ->
    X = etorrent_bcoding:search_dict_default({string, "min interval"},
                                             BC,
                                             none),
    case X of
        {integer, R} -> R;
        none -> none
    end.

%%--------------------------------------------------------------------
%% Function: decode_ips(IpData) -> [{IP, Port}]
%% Description: Decode the IP response from the tracker
%%--------------------------------------------------------------------
decode_ips(D) ->
    decode_ips(D, []).

decode_ips([], Accum) ->
    Accum;
decode_ips([IPDict | Rest], Accum) ->
    {string, IP} = etorrent_bcoding:search_dict({string, "ip"}, IPDict),
    {integer, Port} = etorrent_bcoding:search_dict({string, "port"},
                                                   IPDict),
    decode_ips(Rest, [{IP, Port} | Accum]);
decode_ips(<<>>, Accum) ->
    Accum;
decode_ips(<<B1:8, B2:8, B3:8, B4:8, Port:16/big, Rest/binary>>, Accum) ->
    decode_ips(Rest, [{{B1, B2, B3, B4}, Port} | Accum]);
decode_ips(Odd, Accum) ->
    ?INFO([tracker_wrong_ip_decode, Odd]),
    Accum.


response_ips(BC) ->
    case etorrent_bcoding:search_dict_default({string, "peers"}, BC, none) of
        {list, Ips} ->
            decode_ips(Ips);
        {string, Ips} ->
            decode_ips(list_to_binary(Ips));
        none ->
            []
    end.

tracker_id(BC) ->
    etorrent_bcoding:search_dict_default({string, "trackerid"},
                                BC,
                                tracker_id_not_given).

decode_integer(Target, BC) ->
    case etorrent_bcoding:search_dict_default({string, Target}, BC, none) of
        {integer, N} ->
            N;
        none ->
            0
    end.

fetch_error_message(BC) ->
    etorrent_bcoding:search_dict_default({string, "failure reason"}, BC, none).

fetch_warning_message(BC) ->
    etorrent_bcoding:search_dict_default({string, "warning message"}, BC, none).

shuffle_tiers(Tiers) ->
    [etorrent_utils:shuffle(T) || T <- Tiers].
