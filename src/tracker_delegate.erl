-module(tracker_delegate).
-behaviour(gen_server).

-export([init/1, handle_cast/2, code_change/3, terminate/2, handle_info/2, handle_call/3]).

-author("jesper.louis.andersen@gmail.com").

-record(tracker_request,{port = none,
			 uploaded = 0,
			 downloaded = 0,
			 left = 0}).

-define(DEFAULT_REQUEST_TIMEOUT, 180).

init({Master, StatePid, Url, InfoHash, PeerId}) ->
    {ok, {Master, StatePid, Url, InfoHash, PeerId}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_info(_Foo, State) ->
    {noreply, State}.

terminate(shutdown, _State) ->
    ok.

handle_call(_Call, _Who, S) ->
    {noreply, S}.

tick_after(Secs) ->
    timer:apply_after(Secs * 1000, self(),
		      fun () -> request_tracker_immediately(self()) end, []).

handle_cast(tracker_request_now, State) ->
    tracker_request(State, none);
handle_cast(start, State) ->
    tracker_request(State, "started");
handle_cast(stop, State) ->
    tracker_request(State, "stopped").

%% Operations
request_tracker_immediately(Pid) ->
    gen_server:cast(Pid, tracker_request_now).

%% Helpers
build_request_to_send(StatePid) ->
    {data_transfer_amounts, Uploaded, Downloaded, Left} =
	torrent_state:current_state(StatePid),
    io:format("Building request to send~n"),
    #tracker_request{uploaded = Uploaded,
		     downloaded = Downloaded,
		     left = Left}.

find_in_bcoded(BCoded, Term, Default) ->
    case bcoding:search_dict(Term, BCoded) of
	{ok, Val} ->
	    Val;
	_ ->
	    Default
    end.

find_next_request_time(BCoded) ->
    find_in_bcoded(BCoded, "interval", ?DEFAULT_REQUEST_TIMEOUT).

find_ips_in_tracker_response(BCoded) ->
    find_in_bcoded(BCoded, "peers", []).

find_tracker_id(BCoded) ->
    find_in_bcoded(BCoded, "trackerid", tracker_id_not_given).

find_completes(BCoded) ->
    find_in_bcoded(BCoded, "complete", no_completes).

find_incompletes(BCoded) ->
    find_in_bcoded(BCoded, "incomplete", no_incompletes).

fetch_error_message(BC) ->
    find_in_bcoded(BC, "failure reason", none).

fetch_warning_message(BC) ->
    find_in_bcoded(BC, "warning message", none).

handle_tracker_response(BC, Master) ->
    RequestTime = find_next_request_time(BC),
    TrackerId = find_tracker_id(BC),
    Complete = find_completes(BC),
    Incomplete = find_incompletes(BC),
    NewIPs = find_ips_in_tracker_response(BC),
    ErrorMessage = fetch_error_message(BC),
    WarningMessage = fetch_warning_message(BC),
    if
	ErrorMessage /= none ->
	    gen_server:cast(Master, {tracker_error_report, ErrorMessage});
	WarningMessage /= none ->
	    gen_server:cast(Master, {tracker_warning_report, WarningMessage}),
	    gen_server:cast(Master, {tracker_report, TrackerId, Complete, Incomplete}),
	    gen_server:cast(Master, {new_ips, NewIPs});
	true ->
	    get_server:cast(Master, {tracker_report, TrackerId, Complete, Incomplete}),
	    gen_server:cast(Master, {new_ips, NewIPs})
    end,
    tick_after(RequestTime).

tracker_request({Master, StatePid, Url, InfoHash, PeerId}, Event) ->
    RequestToSend = build_request_to_send(StatePid),
    case perform_get_request(Url, InfoHash, PeerId, RequestToSend, Event) of
	{ok, ResponseBody} ->
	    case bcoding:decode(ResponseBody) of
		{ok, BC} ->
		    handle_tracker_response(BC, Master),
		    {noreply, {Master, StatePid, Url, InfoHash, PeerId}};
		{error, Err} ->
		    gen_server:cast(Master, {tracker_responded_not_bcode, Err}),
		    tick_after(180),
		    {noreply, {Master, StatePid, Url, InfoHash, PeerId}}
	    end;
	{error, Err} ->
	    gen_server:cast(Master, {tracker_request_failed, Err}),
	    tick_after(180),
	    {noreply, {Master, StatePid, Url, InfoHash, PeerId}}
    end.

perform_get_request(Url, InfoHash, PeerId, Status, Event) ->
    NewUrl = build_tracker_url(Url, Status, InfoHash, PeerId, Event),
    case http:request(NewUrl) of
	{ok, {{_, 200, _}, _, Body}} ->
	    {ok, Body};
	_ ->
	    %% TODO: We need to fix this. If we can't find anything, this is
	    %% triggered. So we must handle it. Oh, we must fix this.
	    %% We can take a look on some of the errors and report them back gracefully since it is much easier
	    %% to read and understand then.
	    {error, "Some error happened in the request get"}
    end.

build_tracker_url(BaseUrl, TrackerRequest, IHash, PrId, Evt) ->
    InfoHash = lists:concat(["info_hash=", IHash]),
    PeerId   = lists:concat(["peer_id=", PrId]),
    %% Ignore port for now
    Uploaded = lists:concat(["uploaded=",
			     TrackerRequest#tracker_request.uploaded]),
    Downloaded = lists:concat(["downloaded=",
			       TrackerRequest#tracker_request.downloaded]),
    Left = lists:concat(["left=", TrackerRequest#tracker_request.left]),
    Event = case Evt of
		none -> "";
		E -> lists:concat(["&event=", E])
	    end,
    lists:concat([BaseUrl, "?",
		  InfoHash, "&",
		  PeerId, "&",
		  Uploaded, "&",
		  Downloaded, "&",
		  Left, %% The Event adds this itself.
		  Event]).
