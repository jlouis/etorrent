-module(torrent_state).

-compile(export_all).

-record(torrent_state, {uploaded = 0,
			downloaded = 0,
			left = 0}).

start() ->
    spawn(torrent_state, init, []).

init() ->
    torrent_state_loop(#torrent_state{}).

torrent_state_loop(State) ->
    io:format("State looping~n"),
    NewState = receive
		   {i_uploaded_data, Amount} ->
		       update_uploaded(Amount, State);
		   {i_downloaded_data, Amount} ->
		       update_downloaded(Amount, State);
		   {i_got_a_piece, Amount} ->
		       update_left(Amount, State);
		   {current_state, Who} ->
		       io:format("Reporting information to ~w~n", [Who]),
		       Who ! report_state_information(State),
		       State;
		   stop ->
		       exit(normal)
	       end,
    torrent_state:torrent_state_loop(NewState).

new() ->
    #torrent_state{}.

report_state_information(State) ->
    {data_transfer_amounts,
     State#torrent_state.uploaded,
     State#torrent_state.downloaded,
     State#torrent_state.left}.

update_uploaded(Amount, State) ->
    CurAmount = State#torrent_state.uploaded,
    State#torrent_state{uploaded = CurAmount + Amount}.

update_downloaded(Amount, State) ->
    CurAmount = State#torrent_state.downloaded,
    State#torrent_state{downloaded = CurAmount + Amount}.

update_left(Amount, State) ->
    CurAmount = State#torrent_state.left,
    State#torrent_state{left = CurAmount + Amount}.
