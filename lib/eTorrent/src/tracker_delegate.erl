%%%-------------------------------------------------------------------
%%% File    : tracker_delegate.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Handles communication
%%%
%%% Created : 17 Jul 2007 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(tracker_delegate).

-behaviour(gen_server).

%% API
-export([start_link/5, contact_tracker_now/1, start_now/1, stop_now/1,
	torrent_completed/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {should_contact_tracker = false,
	        state_pid = none,
	        url = none,
	        info_hash = none,
	        peer_id = none,
		trackerid = none,
		time_left = 0,
		timer = none,
	        control_pid = none}).

-define(DEFAULT_REQUEST_TIMEOUT, 180).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(ControlPid, StatePid, Url, InfoHash, PeerId) ->
    gen_server:start_link(?MODULE,
			  [{ControlPid, StatePid, Url, InfoHash, PeerId}],
			  []).

contact_tracker_now(Pid) ->
    gen_server:cast(Pid, contact_tracker_now).

start_now(Pid) ->
    gen_server:cast(Pid, start_now).

stop_now(Pid) ->
    gen_server:cast(Pid, stop_now).

torrent_completed(Pid) ->
    gen_server:cast(Pid, torrent_completed).

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
init([{ControlPid, StatePid, Url, InfoHash, PeerId}]) ->
    {ok, #state{should_contact_tracker = false,
		control_pid = ControlPid,
		state_pid = StatePid,
		url = Url,
		info_hash = InfoHash,
		peer_id = PeerId}}.

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
%%--------------------------------------------------------------------
handle_cast(start_now, S) ->
    {ok, NextRequestTime, NS} = contact_tracker(S, "started"),
    {noreply, NS, timer:seconds(NextRequestTime)};
handle_cast(stop_now, S) ->
    {ok, NextRequestTime, NS} = contact_tracker(S, "stopped"),
    {noreply, NS, timer:seconds(NextRequestTime)};
handle_cast(torrent_completed, S) ->
    {ok, NextRequestTime, NS} = contact_tracker(S, "completed"),
    {noreply, NS, timer:seconds(NextRequestTime)}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(timeout, S) ->
    {ok, NextRequestTime, NS} = contact_tracker(S, none),
    {noreply, NS, timer:seconds(NextRequestTime)};
handle_info(Info, State) ->
    io:format("got info: ~p~n", [Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(Reason, _State) ->
    io:format("I am dying! ~p~n", [Reason]),
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
contact_tracker(S, Event) ->
    NewUrl = build_tracker_url(S, Event),
    io:format("~s~n", [NewUrl]),
    case http:request(NewUrl) of
	{ok, {{_, 200, _}, _, Body}} ->
	    decode_and_handle_body(Body, S)
    end.

decode_and_handle_body(Body, S) ->
    case bcoding:decode(Body) of
	{ok, BC} ->
	    handle_tracker_response(BC, S)
    end.

handle_tracker_response(BC, S) ->
    io:format("~p~n", [BC]),
    ControlPid = S#state.control_pid,
    StatePid = S#state.state_pid,
    RequestTime = find_next_request_time(BC),
    TrackerId = find_tracker_id(BC),
    Complete = find_completes(BC),
    Incomplete = find_incompletes(BC),
    NewIPs = find_ips_in_tracker_response(BC),
    ErrorMessage = fetch_error_message(BC),
    io:format("Error msg: ~p~n", [ErrorMessage]),
    WarningMessage = fetch_warning_message(BC),
    if
	ErrorMessage /= none ->
	    {string, E} = ErrorMessage,
	    torrent_control:tracker_error_report(ControlPid, E);
	WarningMessage /= none ->
	    torrent_control:tracker_warning_report(ControlPid, WarningMessage),
	    torrent_control:new_peers(ControlPid, NewIPs),
	    torrent_state:report_from_tracker(StatePid, Complete, Incomplete);
	true ->
	    torrent_control:new_peers(ControlPid, NewIPs),
	    torrent_state:report_from_tracker(StatePid, Complete, Incomplete)
    end,
    {ok, RequestTime, S#state{trackerid = TrackerId}}.

construct_headers([], HeaderLines) ->
    lists:concat(lists:reverse(HeaderLines));
construct_headers([{Key, Value}], HeaderLines) ->
    Data = lists:concat([Key, "=", Value]),
    construct_headers([], [Data | HeaderLines]);
construct_headers([{Key, Value} | Rest], HeaderLines) ->
    Data = lists:concat([Key, "=", Value, "&"]),
    construct_headers(Rest, [Data | HeaderLines]).

build_tracker_url(S, Event) ->
    {ok, Downloaded, Uploaded, Left, Port} =
	torrent_state:report_to_tracker(S#state.state_pid),
    Request = [{"info_hash", S#state.info_hash},
	       {"peer_id", S#state.peer_id},
	       {"uploaded", Uploaded},
	       {"downloaded", Downloaded},
	       {"left", Left},
	       {"port", Port}],
    EReq = case Event of
	       none ->
		   Request;
	       X -> [{"event", X} | Request]
	   end,
    lists:concat([S#state.url, "?", construct_headers(EReq, [])]).

%%% Tracker response lookup functions
find_next_request_time(BC) ->
    {integer, R} = bcoding:search_dict_default({string, "interval"},
					       BC,
					       {integer,
						?DEFAULT_REQUEST_TIMEOUT}),
    R.

find_ips_in_tracker_response(BC) ->
    bcoding:search_dict_default({string, "peer"}, BC, []).

find_tracker_id(BC) ->
    bcoding:search_dict_default({string, "trackerid"},
				BC,
				tracker_id_not_given).

find_completes(BC) ->
    bcoding:search_dict_default({string, "complete"}, BC, no_completes).

find_incompletes(BC) ->
    bcoding:search_dict_default({string, "incomplete"}, BC, no_incompletes).

fetch_error_message(BC) ->
    bcoding:search_dict_default({string, "failure reason"}, BC, none).

fetch_warning_message(BC) ->
    bcoding:search_dict_default({string, "warning message"}, BC, none).

