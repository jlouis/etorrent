%%% @author Jesper Louis andersen <jesper.louis.andersen@gmail.com>
%%% @copyright (C) 2011, Jesper Louis andersen
%%% @doc Generic server interface for uTP
%%% @end
-module(gen_utp).

-include("utp.hrl").

-behaviour(gen_server).

%% API (Supervisor)
-export([start_link/1, start_link/2]).

%% API (Use)
-export([connect/2, connect/3, close/1,
	 send/2,
	 recv/2, recv/3,
	 listen/1, accept/0]).

%% Internally used API
-export([register_process/2,
	 lookup_registrar/1,
	 incoming_new/3]).

-type utp_socket() :: {utp_sock, pid()}.
-export_type([utp_socket/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(TAB, ?MODULE).

-record(state, { monitored :: gb_tree(),
	         socket    :: gen_udp:socket(),
	         listen_queue :: closed | {queue, integer(), integer(), queue()} }).

-record(accept_queue,
	{ acceptors      :: queue(),
	  incoming_conns :: queue(),
	  q_len          :: integer(),
	  max_q_len      :: integer() }).

%%%===================================================================

%% @doc Starts the server
%% Options is a proplist of options, given in the spec.
%% @end
%% @todo Strengthen spec
-spec start_link(integer(), proplists:proplist()) ->
			any().
start_link(Port, Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Port, Opts], []).

%% @equiv start_link(Port, [])
-spec start_link(integer()) ->
			any().
start_link(Port) ->
    start_link(Port, []).

%% @equiv connect(Addr, Port, [])
connect(Addr, Port) ->
    connect(Addr, Port, []).

%% @doc Connect to a foreign uTP peer
%% @end
connect(Addr, Port, Options) ->
    {ok, Socket} = get_socket(),
    {ok, Pid} = gen_utp_pool:start_child(Socket, Addr, Port, Options),
    gen_utp_worker:connect(Pid).

accept() ->
    %% Accept an incoming connection.
    %% @todo timeouts!
    %% We handle the SynPacket here because because it is then the caller that gets to work
    %% with the result of the worker process directly, rather than the gen_utp proxy having
    %% to do it.
    {ok, Pid, SynPacket} = call(accept),
    gen_utp_worker:accept(Pid, SynPacket).

%% @doc Send a message on a uTP Socket
%% @end
-spec send(utp_socket(), iolist()) -> ok | {error, term()}.
send({utp_sock, Pid}, Msg) ->
    gen_utp_worker:send(Pid, Msg).

%% @equiv recv(Socket, Length, infinity)
-spec recv(utp_socket(), integer()) -> {ok, binary()} | {error, term()}.
recv({utp_sock, Pid}, Length) ->
    recv(Pid, Length, infinity).

%% @doc Receive a message with a timeout
%% @end
-spec recv(utp_socket(), integer(), infinity | integer()) ->
		  {ok, binary()} | {error, term()}.
recv({utp_sock, Pid}, Length, Timeout) ->
    gen_utp_worker:recv(Pid, Length, Timeout).

%% @doc Close down a socket (nonblocking)
%% @end
close({utp_sock, Pid}) ->
    gen_utp_worker:close(Pid).

%% @doc Listen on socket, with queue length Q
%% @end
listen(QLen) ->
    call({listen, QLen}).

%% @doc New unknown incoming packet
incoming_new(#packet { ty = st_syn } = Packet, Addr, Port) ->
    %% SYN packet, so pass it in
    gen_server:cast(?MODULE, {incoming_syn, Packet, Addr, Port});
incoming_new(#packet{}, _Addr, _Port) ->
    %% Stray, ignore
    ok.


%% @doc Register a process as the recipient of a given incoming message
%% @end
register_process(Pid, ConnID) ->
    call({reg_proc, Pid, ConnID}).

%% @doc Look up the registrar underneath a given connection ID
%% @end
lookup_registrar(CID) ->
    case ets:lookup(?TAB, CID) of
	[] ->
	    not_found;
	[{_, Pid}] ->
	    {ok, Pid}
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Port, Opts]) ->
    {ok, Socket} = gen_udp:open(Port, [binary, {active, once}] ++ Opts),
    true = ets:new(?TAB, [named_table, protected, set]),
    {ok, #state{ monitored = gb_trees:new(),
		 listen_queue = closed,
		 socket = Socket }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(accept, _From, #state { listen_queue = closed } = S) ->
    {reply, {error, no_listen}, S};
handle_call(accept, From, #state { listen_queue = Q,
				   socket = Socket } = S) ->
    {ok, Pairings, NewQ} = push_acceptor(From, Q),
    [accept_incoming_conn(Socket, Acc, SYN) || {Acc, SYN} <- Pairings],
    {noreply, S#state { listen_queue = NewQ }};
handle_call({listen, QLen}, _From, #state { listen_queue = closed } = S) ->
    {reply, ok, S#state { listen_queue = new_accept_queue(QLen) }};
handle_call({listen, _QLen}, _From, #state { listen_queue = #accept_queue{} } = S) ->
    {reply, {error, ealreadylistening}, S};
handle_call({reg_proc, Proc, CID}, _From, State) ->
    true = ets:insert(?TAB, {CID, Proc}),
    Ref = erlang:monitor(process, Proc),
    {reply, ok, State#state { monitored = gb_trees:insert(Ref, CID) }};
handle_call(get_socket, _From, S) ->
    {reply, {ok, S#state.socket}, S};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%% @private
handle_cast({incoming_syn, _P, _Addr, _Port}, #state { listen_queue = closed } = S) ->
    %% Not listening on queue
    %% @todo RESET sent back here?
    {noreply, S};
handle_cast({incoming_syn, Packet, Addr, Port}, #state { listen_queue = Q,
						         socket = Socket } = S) ->
    Elem = {Packet, Addr, Port},
    case push_syn(Elem, Q) of
	synq_full ->
	    {noreply, S}; % @todo RESET sent back?
	{ok, Pairings, NewQ} ->
	    [accept_incoming_conn(Socket, Acc, SYN) || {Acc, SYN} <- Pairings],
	    {noreply, S#state { listen_queue = NewQ }}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info({udp, _Socket, IP, Port, Datagram},
	    #state { socket = Socket } = S) ->
    %% @todo FLOW CONTROL here, because otherwise we may swamp the decoder.
    gen_utp_decoder:decode_and_dispatch(Datagram, IP, Port),
    %% Quirk out the next packet :)
    inet:setopts(Socket, [{active, once}]),
    {noreply, S};
handle_info({'DOWN', Ref, process, _Pid, _Reason}, #state { monitored = MM } = S) ->
    CID = gb_trees:fetch(Ref, MM),
    true = ets:delete(?TAB, CID),
    {noreply, S#state { monitored = gb_trees:delete(Ref, MM)}};
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

push_acceptor(From, #accept_queue { acceptors = AQ } = Q) ->
    handle_queue(Q#accept_queue { acceptors = queue:in(From, AQ) }, []).

push_syn(_SYNPacket, #accept_queue { q_len          = QLen,
				     max_q_len      = MaxQ}) when QLen >= MaxQ ->
    synq_full;
push_syn(SYNPacket, #accept_queue { incoming_conns = IC,
				    q_len          = QLen } = Q) ->
    handle_queue(Q#accept_queue { incoming_conns = queue:in(SYNPacket, IC),
				  q_len          = QLen + 1 }, []).


handle_queue(#accept_queue { acceptors = AQ,
			     incoming_conns = IC,
			     q_len = QLen } = Q, Pairings) ->
    case {queue:out(AQ), queue:out(IC)} of
	{{{value, Acceptor}, AQ1}, {{value, SYN}, IC1}} ->
	    handle_queue(Q#accept_queue { acceptors = AQ1,
					  incoming_conns = IC1,
					  q_len = QLen - 1 },
			 [{Acceptor, SYN} | Pairings]);
	_ ->
	    {ok, Pairings, Q} % Can't do anymore work for now
    end.

accept_incoming_conn(Socket, From, {SynPacket, Addr, Port}) ->
    {ok, Pid} = gen_utp_worker_pool:start_child(Socket, Addr, Port, []),
    gen_server:reply(From, {ok, Pid, SynPacket}).

new_accept_queue(QLen) ->
    #accept_queue { acceptors = queue:new(),
		    incoming_conns = queue:new(),
		    q_len = 0,
		    max_q_len = QLen }.

get_socket() ->
    call(get_socket).

call(Msg) ->
    gen_server:call(?MODULE, Msg, infinity).




