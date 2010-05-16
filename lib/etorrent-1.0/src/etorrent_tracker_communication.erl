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

%% API
-export([start_link/5]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {should_contact_tracker = false,
                queued_message = none,
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
start_link(ControlPid, Url, InfoHash, PeerId, TorrentId) ->
    gen_server:start_link(?MODULE,
                          [ControlPid,
                            Url, InfoHash, PeerId, TorrentId],
                          []).

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
init([ControlPid, Url, InfoHash, PeerId, TorrentId]) ->
    process_flag(trap_exit, true),
    {ok, HardRef} = timer:send_after(0, hard_timeout),
    {ok, SoftRef} = timer:send_after(timer:seconds(?DEFAULT_CONNECTION_TIMEOUT_INTERVAL),
                                     soft_timeout),
    {ok, #state{should_contact_tracker = false,
                control_pid = ControlPid,
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
%%----------------------p----------------------------------------------
handle_cast(Msg, S) when S#state.hard_timer =:= none ->
    NS = contact_tracker(Msg, S),
    {noreply, NS};
handle_cast(Msg, S) ->
    error_logger:error_report([unknown_msg, Msg]),
    {noreply, S}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(hard_timeout, S) when S#state.queued_message =:= none ->
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

contact_tracker(S) ->
    contact_tracker(none, S).

contact_tracker(Event, S) ->
    NewUrl = build_tracker_url(S, Event),
    error_logger:info_report([{contacting_tracker, NewUrl}]),
    case http_gzip:request(NewUrl) of
        {ok, {{_, 200, _}, _, Body}} ->
            handle_tracker_response(etorrent_bcoding:decode(Body), S);
        {error, etimedout} ->
            handle_timeout(S);
        {error,econnrefused} ->
            handle_timeout(S);
        {error, session_remotly_closed} ->
            handle_timeout(S)
    end.


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
                                      {tracker_report,
                                       decode_integer("complete", BC),
                                       decode_integer("incomplete", BC)}),
    %% Timeout
    TrackerId = tracker_id(BC),
    handle_timeout(BC, S#state { trackerid = TrackerId }).

handle_timeout(S) ->
    Interval = timer:seconds(?DEFAULT_CONNECTION_TIMEOUT_INTERVAL),
    MinInterval = timer:seconds(?DEFAULT_CONNECTION_TIMEOUT_MIN_INTERVAL),
    handle_timeout(Interval, MinInterval, S).

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
                  {ok, TRef} = timer:send_after(timer:seconds(I), hard_timeout),
                  NS#state { hard_timer = TRef }
          end,
    {ok, TRef2} = timer:send_after(timer:seconds(Interval), soft_timeout),
    NNS#state { soft_timer = TRef2 }.

cancel_timers(S) ->
    NS = case S#state.hard_timer of
             none ->
                 S;
             TRef ->
                 {ok, cancel} = timer:cancel(TRef),
                 S#state { hard_timer = none }
         end,
    case NS#state.soft_timer of
        none ->
            NS;
        TRef2 ->
            {ok, cancel} = timer:cancel(TRef2),
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

build_tracker_url(S, Event) ->
    {torrent_info, Uploaded, Downloaded, Left} =
                etorrent_torrent:find(S#state.torrent_id),
    {ok, Port} = application:get_env(etorrent, port),
    Request = [{"info_hash",
                etorrent_utils:build_encoded_form_rfc1738(S#state.info_hash)},
               {"peer_id",
                etorrent_utils:build_encoded_form_rfc1738(S#state.peer_id)},
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
    lists:concat([S#state.url, "?", construct_headers(EReq, [])]).

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
    error_logger:info_report([tracker_wrong_ip_decode, Odd]),
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

