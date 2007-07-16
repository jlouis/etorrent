%%%-------------------------------------------------------------------
%%% File    : tracker_delegate.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus.local.domain>
%%% Description : Controls the communication with a tracker.
%%%
%%% Created : 12 Jul 2007 by Jesper Louis Andersen <jlouis@succubus.local.domain>
%%%-------------------------------------------------------------------
-module(tracker_delegate).

-behaviour(gen_fsm).

%% API
-export([start_link/5, contact_tracker_now/1, start_now/1, stop_now/1,
	torrent_completed/1]).

%% gen_fsm callbacks
-export([init/1, tracker_wait/2,
	 state_name/3, handle_event/3, handle_sync_event/4,
	 handle_info/3, terminate/3, code_change/4]).

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
%% Function: start_link() -> ok,Pid} | ignore | {error,Error}
%% Description:Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this function
%% does not return until Module:init/1 has returned.
%%--------------------------------------------------------------------
start_link(ControlPid, StatePid, Url, InfoHash, PeerId) ->
    gen_fsm:start_link(?MODULE,
		       [{ControlPid, StatePid, Url, InfoHash, PeerId}],
		       []).

contact_tracker_now(Pid) ->
    gen_fsm:send_event(Pid, contact_tracker_now).

start_now(Pid) ->
    gen_fsm:send_event(Pid, start_now).

stop_now(Pid) ->
    gen_fsm:send_event(Pid, stop_now).

torrent_completed(Pid) ->
    gen_fsm:send_event(Pid, torrent_completed).

%%====================================================================
%% gen_fsm callbacks
%%====================================================================
%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, StateName, State} |
%%                         {ok, StateName, State, Timeout} |
%%                         ignore                              |
%%                         {stop, StopReason}
%% Description:Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/3,4, this function is called by the new process to
%% initialize.
%%--------------------------------------------------------------------
init([{ControlPid, StatePid, Url, InfoHash, PeerId}]) ->
    {ok, tracker_wait, #state{should_contact_tracker = false,
			      control_pid = ControlPid,
			      state_pid = StatePid,
			      url = Url,
			      info_hash = InfoHash,
			      peer_id = PeerId}}.

%%--------------------------------------------------------------------
%% Function:
%% state_name(Event, State) -> {next_state, NextStateName, NextState}|
%%                             {next_state, NextStateName,
%%                                NextState, Timeout} |
%%                             {stop, Reason, NewState}
%% Description:There should be one instance of this function for each possible
%% state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_event/2, the instance of this function with the same name as
%% the current state name StateName is called to handle the event. It is also
%% called if a timeout occurs.
%%--------------------------------------------------------------------
tracker_wait(start_now, S) ->
    {next_state, tracker_wait, handle_nonregular(S, "started")};
tracker_wait(stop_now, S) ->
    {next_state, tracker_wait, handle_nonregular(S, "stopped")};
tracker_wait(torrent_completed, S) ->
    {next_state, tracker_wait, handle_nonregular(S, "completed")};
tracker_wait({timeout, R, reinstall_timer}, S) ->
    R = S#state.timer,
    NS = install_timer(S#state.time_left, S),
    {next_state, tracker_wait, NS};
tracker_wait({timeout, R, may_contact}, S) ->
    R = S#state.timer,
    {next_state, tracker_wait, handle_tracker_contact(S, none)}.

%%--------------------------------------------------------------------
%% Function:
%% state_name(Event, From, State) -> {next_state, NextStateName, NextState} |
%%                                   {next_state, NextStateName,
%%                                     NextState, Timeout} |
%%                                   {reply, Reply, NextStateName, NextState}|
%%                                   {reply, Reply, NextStateName,
%%                                    NextState, Timeout} |
%%                                   {stop, Reason, NewState}|
%%                                   {stop, Reason, Reply, NewState}
%% Description: There should be one instance of this function for each
%% possible state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_event/2,3, the instance of this function with the same
%% name as the current state name StateName is called to handle the event.
%%--------------------------------------------------------------------
state_name(_Event, _From, State) ->
    Reply = ok,
    {reply, Reply, state_name, State}.

%%--------------------------------------------------------------------
%% Function:
%% handle_event(Event, StateName, State) -> {next_state, NextStateName,
%%						  NextState} |
%%                                          {next_state, NextStateName,
%%					          NextState, Timeout} |
%%                                          {stop, Reason, NewState}
%% Description: Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%--------------------------------------------------------------------
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% Function:
%% handle_sync_event(Event, From, StateName,
%%                   State) -> {next_state, NextStateName, NextState} |
%%                             {next_state, NextStateName, NextState,
%%                              Timeout} |
%%                             {reply, Reply, NextStateName, NextState}|
%%                             {reply, Reply, NextStateName, NextState,
%%                              Timeout} |
%%                             {stop, Reason, NewState} |
%%                             {stop, Reason, Reply, NewState}
%% Description: Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/2,3, this function is called to handle
%% the event.
%%--------------------------------------------------------------------
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%%--------------------------------------------------------------------
%% Function:
%% handle_info(Info,StateName,State)-> {next_state, NextStateName, NextState}|
%%                                     {next_state, NextStateName, NextState,
%%                                       Timeout} |
%%                                     {stop, Reason, NewState}
%% Description: This function is called by a gen_fsm when it receives any
%% other message than a synchronous or asynchronous event
%% (or a system message).
%%--------------------------------------------------------------------
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, StateName, State) -> void()
%% Description:This function is called by a gen_fsm when it is about
%% to terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _StateName, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Function:
%% code_change(OldVsn, StateName, State, Extra) -> {ok, StateName, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

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

%% TODO: Can be made better yet, I am sure! Generalize into a proper code
%%   construction.

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

handle_tracker_contact(S, Event) ->
    {ok, NextContactTime, NS} = contact_tracker(S, Event),
    install_timer(NextContactTime, NS).

install_timer(ContactTime, S) ->
    if
	ContactTime > 30 ->
	    io:format("Setting 30 sec timer! (~B left)~n", [ContactTime]),
	    TimerRef = gen_fsm:start_timer(timer:seconds(30),
					   reinstall_timer),
	    S#state{timer = TimerRef,
		    time_left = ContactTime - 30};
	true ->
	    io:format("Setting timer of ~B seconds~n", [ContactTime]),
	    TimerRef = gen_fsm:start_timer(timer:seconds(ContactTime),
					   may_contact),
	    S#state{timer = TimerRef,
		    time_left = 0}
    end.

handle_nonregular(S, Event) ->
    NS = remove_timer(S),
    handle_tracker_contact(NS, Event).

remove_timer(S) ->
    T = S#state.timer,
    case T of
	none -> S;
	Ref ->
	    X = gen_fsm:cancel_timer(Ref),
	    io:format("Timer cancelled again: ~p~n", [X]),
	    S#state{timer = none,
		    time_left = none}
    end.

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

