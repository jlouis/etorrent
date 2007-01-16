-module(torrent_state).
-behaviour(gen_server).
-export([code_change/3, handle_call/3, handle_cast/2, handle_info/2, init/1, terminate/2]).

-record(torrent_state, {uploaded = 0,
			downloaded = 0,
			left = 0}).

init(_I) ->
    {ok, new()}.

terminate(showdown, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_info(_Foo, State) ->
    {noreply, State}.

handle_call(current_state, Who, State) ->
    io:format("Reporting information to ~w~n", [Who]),
    {reply, report_state_information(State), State}.

handle_cast({i_uploaded_data, Amount}, State) ->
    {noreply, update_uploaded(Amount, State)};
handle_cast({i_downloaded_data, Amount}, State) ->
    {noreply, update_downloaded(Amount, State)};
handle_cast({i_got_a_piece, Amount}, State) ->
    {noreply, update_left(Amount, State)}.

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
