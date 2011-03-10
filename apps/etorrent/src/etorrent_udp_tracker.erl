%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Track an UDP request event and handle its communication/timeout.
%% <p>This gen_server tracks a single announce-request for a tracker
%% client. There are actually two different types of requestors baked
%% into the gen-server. One for getting hold of a Connection ID, and
%% one for doing actual requests.</p>
%% <p>It is also the case that these processes are the ones that reply
%% back to the client. So the clients request goes through the
%% tracker_mgr process and ends up here. When we have data, they get
%% sent back via a gen_server:reply. Also note that protocol decoding
%% is separately handled by the trakcer_proto process. The proto looks
%% up the relevant recipient - a gen_server from this module and sends
%% the message to it.</p>
%% <p>The API is mostly internal, assumed to be used with the other
%% udp_tracker processes.</p>
%%@end
-module(etorrent_udp_tracker).
-include("log.hrl").

-behaviour(gen_server).

%% API
-export([start_link/3, start_link/4]).

%% Internally used calls
-export([msg/2, connid/2, cancel/1, cancel_connid/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-type ipaddr() :: etorrent_types:ipaddr().
-type portnum() :: etorrent_types:portnum().
-type from_tag() :: etorrent_types:from_tag().
-record(state, { try_count = -1 :: integer(),
	         tracker        :: tracker_id(),
		 ty             :: announce | connid_gather,
		 connid = none  :: none | integer(),
		 reply = none   :: none | from_tag(),
		 properties = [] :: [{term(), term()}], % Proplist
	         tid = none      :: none | binary() }).
-type tracker_id() :: {ipaddr(), portnum()}.
-type conn_id() :: integer().

-define(CONNID_TIMEOUT, timer:seconds(60)).

%%====================================================================
%% API
%%====================================================================

%%====================================================================

%% @doc Start a request for a ConnId on Tracker.
%%   The given N is used as a retry-count
%% @end
-spec start_link('requestor', tracker_id(), integer()) ->
			{ok, pid()} | {error, term()}.
start_link(requestor, Tracker, N) ->
    gen_server:start_link(?MODULE, [{connid_gather, Tracker, N}], []).

%% @doc Start a normal announce-request
%%   We are given to whom we should reply back in From, what Tracker
%%   to call up, and a list of properties to send forth.
%% @end
-spec start_link('announce',from_tag(),tracker_id(),_) ->
			'ignore' | {'error',_} | {'ok',pid()}.
start_link(announce, From, Tracker, PL) ->
    gen_server:start_link(?MODULE, [{announce, From, Tracker, PL}], []).

%% This internal function is used to forward a working connid to an announcer
%% @private
-spec connid(pid(),conn_id()) -> 'ok'.
connid(Pid, ConnID) ->
    gen_server:cast(Pid, {connid, ConnID}).

%% @doc Cancel a request event process
%% @end
-spec cancel(pid()) -> 'ok'.
cancel(Pid) ->
    gen_server:cast(Pid, cancel).

%% Sent when a connid expires (60 seconds per spec)
%% @private
-spec cancel_connid(pid(),conn_id()) -> 'ok'.
cancel_connid(Pid, ConnID) ->
    gen_server:cast(Pid, {cancel, ConnID}).

%% Used internally for the proto_decoder to inject a message to an
%% event handler process
%% @private
-spec msg(pid(), term()) -> 'ok'. %% @todo Strengthen 'term()'
msg(Pid, M) ->
    gen_server:cast(Pid, {msg, M}).

%%====================================================================

%% @private
init([{announce, From, Tracker, PL}]) ->
    etorrent_udp_tracker_mgr:reg_announce(Tracker, PL),
    {ok, #state { tracker = Tracker, ty = announce, reply = From, properties = PL }};
init([{connid_gather, Tracker, N}]) ->
    etorrent_udp_tracker_mgr:reg_connid_gather(Tracker),
    {ok, #state { tracker = Tracker, ty = connid_gather, try_count = N}, 0}.

%% @private
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%% @private
handle_cast(cancel, S) ->
    {stop, normal, S};
handle_cast({connid, ConnID}, #state { ty = announce,
				       properties = PL,
				       tracker = Tracker } = S) ->
    Tid = announce_request(Tracker, ConnID, PL, 0),
    {noreply, S#state { connid = ConnID, try_count = 0, tid = Tid }};
handle_cast({cancel_connid, ConnID}, #state { connid = ConnID} = S) ->
    {noreply, S#state { connid = none }};
handle_cast({msg, {Tid, {announce_response, Peers, Status}}},
	    #state { reply = R, ty = announce, tid = Tid } = S) ->
    etorrent_udp_tracker_mgr:unreg_tr_id(Tid),
    announce_reply(R, Peers, Status),
    {stop, normal, S};
handle_cast({msg, {Tid, {conn_response, ConnID}}},
	    #state { tracker = Tracker, tid = Tid } = S) ->
    etorrent_udp_tracker_mgr:unreg_tr_id(Tid),
    erlang:send_after(?CONNID_TIMEOUT, etorrent_udp_tracker_mgr, {remove_connid, Tracker, ConnID}),
    etorrent_udp_tracker_mgr:reg_connid(Tracker, ConnID),
    etorrent_udp_tracker_mgr:distribute_connid(Tracker, ConnID),
    {stop, normal, S};
handle_cast(Msg, State) ->
    ?WARN([unknown_msg, Msg]),
    {noreply, State}.

%% @private
handle_info(timeout, #state { tracker=Tracker,
			      try_count=N,
			      ty = announce,
			      tid = OldTid,
			      connid = ConnID } = S) ->
    case OldTid of
	none -> ignore;
	T when is_binary(T) -> etorrent_udp_tracker_mgr:unreg_tr_id(OldTid)
    end,
    case ConnID of
	none ->
	    etorrent_udp_tracker_mgr:need_requestor(Tracker, N),
	    {noreply, S#state { tid = none, try_count = 0 }};
	K when is_integer(K) ->
	    Tid = announce_request(Tracker, ConnID, S#state.properties, inc(N)),
	    {noreply, S#state { tid = Tid, try_count = inc(N)}}
    end;
handle_info(timeout, #state { tracker=Tracker, try_count=N, ty = connid_gather, tid = OldTid } = S) ->
    case OldTid of
	none -> ignore;
	T when is_binary(T) -> etorrent_udp_tracker_mgr:unreg_tr_id(OldTid)
    end,
    Tid = request_connid(Tracker, inc(N)),
    {noreply, S#state { tid = Tid, try_count = inc(N) }};
handle_info(Info, State) ->
    ?WARN([unknown, Info]),
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------

announce_request({IP, Port}, ConnID, PropL, N) ->
    [IH, PeerId, Down, Left, Up, Event, Key, Port] =
	[proplists:get_value(K, PropL)
	 || K <- [info_hash, peer_id, down, left, up, event, key, port]],
    Tid = etorrent_udp_tracker_proto:new_tid(),
    etorrent_udp_tracker_mgr:reg_tr_id(Tid),
    erlang:send_after(expire_time(N), self(), timeout),
    Msg = {announce_request, ConnID, Tid, IH, PeerId, {Down, Left, Up}, Event, Key,
	   Port},
    etorrent_udp_tracker_mgr:msg({IP, Port}, Msg),
    Tid.

request_connid({IP, Port}, N) ->
    Tid = etorrent_udp_tracker_proto:new_tid(),
    etorrent_udp_tracker_mgr:reg_tr_id(Tid),
    erlang:send_after(expire_time(N), self(), timeout),
    Msg = {conn_request, Tid},
    etorrent_udp_tracker_mgr:msg({IP, Port}, Msg),
    Tid.

expire_time(N) ->
    timer:seconds(
      15 * trunc(math:pow(2,N))).

announce_reply(From, Peers, Status) ->
    gen_server:reply(From, {announce, Peers, Status}).

inc(8) -> 8;
inc(N) when is_integer(N), N < 8 ->
    N+1.
