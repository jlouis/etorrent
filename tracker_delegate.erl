-module(tracker_delegate).

-compile(export_all).

-author("jesper.louis.andersen@gmail.com").

-record(tracker_request,{port = none,
			 uploaded = 0,
			 downloaded = 0,
			 left = 0}).



start(Master, StatePid, Url, InfoHash, PeerId) ->
    spawn(tracker_delegate, init, [Master, StatePid, Url, InfoHash, PeerId]).

init(Master, StatePid, Url, InfoHash, PeerId) ->
    delegate_loop(Master, StatePid, Url, InfoHash, PeerId).

tick_after(Secs) ->
    timer:send_after(Secs * 1000, self(), tracker_request_now).

fetch_state(StatePid) ->
    StatePid ! {current_state, self()},
    receive
	{data_transfer_amounts, Uploaded, Downloaded, Left} ->
	    {Uploaded, Downloaded, Left}
    end.

build_request_to_send(StatePid) ->
    {Uploaded, Downloaded, Left} = fetch_state(StatePid),
    io:format("Building request to send~n"),
    #tracker_request{uploaded = Uploaded,
		     downloaded = Downloaded,
		     left = Left}.

dummy_request() ->
    #tracker_request{uploaded = 0, downloaded = 0, left = 0}.

delegate_loop(Master, StatePid, Url, InfoHash, PeerId) ->
    io:format("Delegate loop entered~n"),
    receive
	tracker_request_now ->
	    tracker_request(Master, StatePid, Url, InfoHash, PeerId, none);
	start ->
	    io:format("Requesting tracker~n"),
	    tracker_request(Master, StatePid, Url, InfoHash, PeerId,
			    "started");
	stop ->
	    %% Ignore answer
	    RequestToSend = build_request_to_send(StatePid),
	    perform_get_request(Url, InfoHash, PeerId, RequestToSend,
			       "stopped"),
	    exit(normal)
    end,
    tracker_delegate:delegate_loop(Master, StatePid, Url, InfoHash,
				   PeerId).

find_next_request_time(BCoded) ->
    case bcoding:search_dict("interval", BCoded) of
	{ok, Num} ->
	    Num;
	_ ->
	    default_request_timeout()
    end.

default_request_timeout() ->
    180.

tracker_request(Master, StatePid, Url, InfoHash, PeerId, Event) ->
    RequestToSend = build_request_to_send(StatePid),
    io:format("Sending request: ~w~n", [RequestToSend]),
    case perform_get_request(Url, InfoHash, PeerId, RequestToSend, Event) of
	{ok, ResponseBody} ->
	    case bcoding:decode(ResponseBody) of
		{ok, BC} ->
		    RequestTime = find_next_request_time(BC),
		    Master ! {new_tracker_response, BC},
		    tick_after(RequestTime),
		    ok;
		{error, Err} ->
		    Master ! {tracker_responded_not_bcode, Err},
		    tick_after(180),
		    ok
	    end;
	{error, Err} ->
	    io:format("Error occurred while contacting tracker"),
	    Master ! {tracker_request_failed, Err},
	    tick_after(180)
    end.

perform_get_request(Url, InfoHash, PeerId, Status, Event) ->
    io:format("building tracker url~n"),
    NewUrl = build_tracker_url(Url, Status, InfoHash, PeerId, Event),
    io:format("Built...~n"),
    case http:request(NewUrl) of
	{ok, {{_, 200, _}, _, Body}} ->
	    {ok, Body};
	_ ->
	    %% TODO: We need to fix this. If we can't find anything, this is
	    %% triggered. So we must handle it. Oh, we must fix this.
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
