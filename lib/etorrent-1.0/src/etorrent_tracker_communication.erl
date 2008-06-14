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

-include("etorrent_mnesia_table.hrl").

%% API
-export([start_link/6, contact_tracker_now/1, start_now/1, stop_now/1,
	torrent_completed/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {should_contact_tracker = false,
		queued_message = none,
		peer_master_pid = none,
	        url = none,
	        info_hash = none,
	        peer_id = none,
		trackerid = none,
		time_left = 0,
		timer = none,
		control_pid = none,
		torrent_id = none}).

-define(DEFAULT_REQUEST_TIMEOUT, 180).
-define(DEFAULT_CONNECTION_TIMEOUT_INTERVAL, 1800).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(ControlPid, PeerMasterPid, Url, InfoHash, PeerId, TorrentId) ->
    gen_server:start_link(?MODULE,
			  [ControlPid, PeerMasterPid,
			    Url, InfoHash, PeerId, TorrentId],
			  []).

contact_tracker_now(Pid) ->
    gen_server:cast(Pid, contact_tracker_now).

start_now(Pid) ->
    gen_server:cast(Pid, start_now).

stop_now(Pid) ->
    gen_server:call(Pid, stop_now).

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
init([ControlPid, PeerMasterPid, Url, InfoHash, PeerId, TorrentId]) ->
    dbg:p(self(), call),
    tr:tr(etorrent_tracker_communication, build_tracker_url),
    {ok, #state{should_contact_tracker = false,
		peer_master_pid = PeerMasterPid,
		control_pid = ControlPid,
		torrent_id = TorrentId,
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
handle_call(stop_now, _From, S) ->
    contact_tracker(S, "stopped"),
    {reply, ok, S};
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
    case contact_tracker(S, "started") of
	{ok, Body} ->
	    {ok, NextRequestTime, NS} = decode_and_handle_body(Body, S),
	    error_logger:info_msg("Will contact again in ~B seconds~n",
				  [NextRequestTime]),
	    {noreply, NS, timer:seconds(NextRequestTime)};
	{error, etimedout} ->
	    {noreply,
	     S#state{queued_message = "started"},
	     timer:seconds(?DEFAULT_CONNECTION_TIMEOUT_INTERVAL)}
    end;
handle_cast(torrent_completed, S) ->
    case contact_tracker(S, "completed") of
	{ok, Body} ->
	    {ok, NextRequestTime, NS} = decode_and_handle_body(Body, S),
	    error_logger:info_msg("Will contact again in ~B seconds~n",
				  [NextRequestTime]),
	    {noreply, NS, timer:seconds(NextRequestTime)};
	{error, etimedout} ->
	    {noreply,
	     S#state{queued_message = "completed"},
	     timer:seconds(?DEFAULT_CONNECTION_TIMEOUT_INTERVAL)}
    end.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(timeout, S) ->
    case contact_tracker(S, S#state.queued_message) of
	{ok, Body} ->
	    {ok, NextRequestTime, NS} = decode_and_handle_body(Body, S),
	    {noreply,
	     NS#state{queued_message=none},
	     timer:seconds(NextRequestTime)};
	{error, timedout} ->
	    {noreply, S, timer:seconds(?DEFAULT_CONNECTION_TIMEOUT_INTERVAL)}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(normal, S) ->
    contact_tracker(S, "stopped"),
    ok;
terminate(_Reason, _S) ->
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
    case http_gzip:request(NewUrl) of
	{ok, {{_, 200, _}, _, Body}} ->
	    {ok, Body};
	{error, E} ->
	    {error, E}
    end.

decode_and_handle_body(Body, S) ->
    case etorrent_bcoding:decode(Body) of
	{ok, BC} ->
	    handle_tracker_response(BC, S)
    end.

handle_tracker_response(BC, S) ->
    ControlPid = S#state.control_pid,
    PeerMasterPid = S#state.peer_master_pid,
    RequestTime = find_next_request_time(BC),
    TrackerId = find_tracker_id(BC),
    Complete = find_completes(BC),
    Incomplete = find_incompletes(BC),
    NewIPs = find_ips_in_tracker_response(BC),
    ErrorMessage = fetch_error_message(BC),
    WarningMessage = fetch_warning_message(BC),
    if
	ErrorMessage /= none ->
	    {string, E} = ErrorMessage,
	    etorrent_t_control:tracker_error_report(ControlPid, E);
	WarningMessage /= none ->
	    etorrent_t_control:tracker_warning_report(ControlPid, WarningMessage),
	    etorrent_t_peer_group:add_peers(PeerMasterPid, NewIPs),
	    etorrent_mnesia_operations:set_torrent_state(S#state.torrent_id,
							 {tracker_report, Complete, Incomplete});
	true ->
	    etorrent_t_peer_group:add_peers(PeerMasterPid, NewIPs),
	    etorrent_mnesia_operations:set_torrent_state(S#state.torrent_id,
							 {tracker_report, Complete, Incomplete})
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
    [R] = etorrent_mnesia_operations:select_torrent(S#state.torrent_id),
    {ok, Port} = application:get_env(etorrent, port),
    Request = [{"info_hash",
		etorrent_utils:build_encoded_form_rfc1738(S#state.info_hash)},
	       {"peer_id",
		etorrent_utils:build_encoded_form_rfc1738(S#state.peer_id)},
	       {"uploaded", R#torrent.uploaded},
	       {"downloaded", R#torrent.downloaded},
	       {"left", R#torrent.left},
	       {"port", Port}],
    EReq = case Event of
	       none ->
		   Request;
	       X -> [{"event", X} | Request]
	   end,
    lists:concat([S#state.url, "?", construct_headers(EReq, [])]).

%%% Tracker response lookup functions
find_next_request_time(BC) ->
    {integer, R} = etorrent_bcoding:search_dict_default({string, "interval"},
						  BC,
						  {integer,
						   ?DEFAULT_REQUEST_TIMEOUT}),
    R.

process_ips(D) ->
    process_ips(D, []).

process_ips([], Accum) ->
    lists:reverse(Accum);
process_ips([IPDict | Rest], Accum) ->
    {ok, {string, IP}} = etorrent_bcoding:search_dict({string, "ip"}, IPDict),
    {ok, {string, PeerId}} = etorrent_bcoding:search_dict({string, "peer id"},
						    IPDict),
    {ok, {integer, Port}} = etorrent_bcoding:search_dict({string, "port"},
						   IPDict),
    process_ips(Rest, [{IP, Port, PeerId} | Accum]).

find_ips_in_tracker_response(BC) ->
    case etorrent_bcoding:search_dict_default({string, "peers"}, BC, none) of
	{list, Ips} ->
	    process_ips(Ips);
	none ->
	    []
    end.

find_tracker_id(BC) ->
    etorrent_bcoding:search_dict_default({string, "trackerid"},
				BC,
				tracker_id_not_given).

find_completes(BC) ->
    etorrent_bcoding:search_dict_default({string, "complete"}, BC, no_completes).

find_incompletes(BC) ->
    etorrent_bcoding:search_dict_default({string, "incomplete"}, BC, no_incompletes).

fetch_error_message(BC) ->
    etorrent_bcoding:search_dict_default({string, "failure reason"}, BC, none).

fetch_warning_message(BC) ->
    etorrent_bcoding:search_dict_default({string, "warning message"}, BC, none).

