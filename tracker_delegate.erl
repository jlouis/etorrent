-module(tracker_delegate).
-behaviour(gen_server).

-export([init/1, handle_cast/2, code_change/3, terminate/2, handle_info/2, handle_call/3]).

-author("jesper.louis.andersen@gmail.com").

-record(tracker_request,{port = none,
			 uploaded = 0,
			 downloaded = 0,
			 left = 0}).

init({Master, StatePid, Url, InfoHash, PeerId}) ->
    {Master, StatePid, Url, InfoHash, PeerId}.

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
		      fun () ->
			      gen_server:cast(self(), tracker_request_now)
		      end, []).

fetch_state(StatePid) ->
    {ok, Reply} = gen_server:call(StatePid, current_state),
    Reply.

build_request_to_send(StatePid) ->
    {Uploaded, Downloaded, Left} = fetch_state(StatePid),
    io:format("Building request to send~n"),
    #tracker_request{uploaded = Uploaded,
		     downloaded = Downloaded,
		     left = Left}.

handle_cast(tracker_request_now, State) ->
    tracker_request(State, none);
handle_cast(start, State) ->
    tracker_request(State, "started");
handle_cast(stop, State) ->
    tracker_request(State, "stopped").

find_next_request_time(BCoded) ->
    case bcoding:search_dict("interval", BCoded) of
	{ok, Num} ->
	    Num;
	_ ->
	    default_request_timeout()
    end.

default_request_timeout() ->
    180.

tracker_request({Master, StatePid, Url, InfoHash, PeerId}, Event) ->
    RequestToSend = build_request_to_send(StatePid),
    io:format("Sending request: ~w~n", [RequestToSend]),
    case perform_get_request(Url, InfoHash, PeerId, RequestToSend, Event) of
	{ok, ResponseBody} ->
	    case bcoding:decode(ResponseBody) of
		{ok, BC} ->
		    RequestTime = find_next_request_time(BC),
		    Master ! {new_tracker_response, BC},
		    tick_after(RequestTime),
		    {noreply, {Master, StatePid, Url, InfoHash, PeerId}};
		{error, Err} ->
		    Master ! {tracker_responded_not_bcode, Err},
		    tick_after(180),
		    {noreply, {Master, StatePid, Url, InfoHash, PeerId}}
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
