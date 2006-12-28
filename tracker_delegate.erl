-module(tracker_delegate).

-compile(export_all).

-author("jesper.louis.andersen@gmail.com").

-record(tracker_request, {info_hash,
			  peer_id,
			  port = none,
			  uploaded = 0,
			  downloaded = 0,
			  left = 0,
			  event = "started"}).


start_tracker_delegate(Url) ->
    spawn(tracker_delegate, delegate, Url).

%% Loop on requests.
%% TODO: Update this so it has a ticker timeout as well.
delegate(Url) ->
    receive
	{get_torrent_info, Who, StateToSend} ->
	    Who ! perform_get_request(Url, StateToSend),
	    tracker_delegate:delegate(Url)
    end.

perform_get_request(Url, StateToSend) ->
    NewUrl = build_tracker_url(Url, StateToSend),
    case http:request(NewUrl) of
	{ok, {{_, 200, _}, _, Body}} ->
	    {ok, Body};
	_ ->
	    {error, "Some error happened in the request get"}
    end.

build_tracker_url(BaseUrl, TrackerRequest) ->
    InfoHash = lists:concat(["info_hash=", TrackerRequest#tracker_request.info_hash]),
    PeerId   = lists:concat(["peer_id=", TrackerRequest#tracker_request.peer_id]),
    %% Ignore port for now
    Uploaded = lists:concat(["uploaded=", TrackerRequest#tracker_request.uploaded]),
    Downloaded = lists:concat(["downloaded=", TrackerRequest#tracker_request.downloaded]),
    Left = lists:concat(["left=", TrackerRequest#tracker_request.left]),
    Event = lists:concat(["event=", TrackerRequest#tracker_request.event]),
    lists:concat([BaseUrl, "?",
		  InfoHash, "&",
		  PeerId, "&",
		  Uploaded, "&",
		  Downloaded, "&",
		  Left, "&",
		  Event]).
