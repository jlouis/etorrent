%%% @author Jesper Louis andersen <jesper.louis.andersen@gmail.com>
%%% @copyright (C) 2011, Jesper Louis andersen
%%% @doc Generic server interface for uTP
%%% @end
-module(gen_utp).

-include("utp.hrl").
-include("log.hrl").

-behaviour(gen_server).

%% API (Supervisor)
-export([start_link/1, start_link/2]).

%% API (Use)
-export([connect/2, connect/3,
         close/1,
         send/2, send_msg/2,
         recv/2, recv_msg/1,
         listen/0, listen/1,
         accept/0]).

%% Internally used API
-export([register_process/2,
         reply/2,
         lookup_registrar/3,
         incoming_unknown/3]).

-type port_number() :: 0..16#FFFF.
-opaque({socket,{type,{30,21},tuple,[{atom,{30,22},utp_sock},{type,{30,32},pid,[]}]},[]}).
-export_type([socket/0]).

-type listen_opts() :: {backlog, integer()}.

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(TAB, ?MODULE).

-record(accept_queue,
        { acceptors      :: queue(),
          incoming_conns :: queue(),
          q_len          :: integer(),
          max_q_len      :: integer() }).

-record(state, { monitored :: gb_tree(),
                 socket    :: inet:socket(),
                 listen_queue :: closed | #accept_queue{},
                 listen_options = [] :: [listen_opts()]}).



%%%===================================================================

%% @doc Starts the server
%% Options is a proplist of options, given in the spec.
%% @end
%% @todo Strengthen spec
-spec start_link(integer(), [{atom(), term()}]) -> any().
start_link(Port, Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Port, Opts], []).

%% @equiv start_link(Port, [])
-spec start_link(integer()) -> any().
start_link(Port) ->
    start_link(Port, []).

%% @equiv connect(Addr, Port, [])
-spec connect(inet:ip_address() | inet:hostname(), port_number()) ->
                     {ok, socket()} | {error, term()}.
connect(Addr, Port) ->
    connect(Addr, Port, []).

%% @doc Connect to a foreign uTP peer
%% @end
-spec connect(inet:ip_address() | inet:hostname(), port_number(), [term()]) ->
                     {ok, socket()} | {error, term()}.
connect(Addr, Port, Options) ->
    {ok, Socket} = get_socket(),
    {ok, Pid} = gen_utp_worker_pool:start_child(Socket, Addr, Port, Options),
    case gen_utp_worker:connect(Pid) of
        ok ->
            {ok, {utp_sock, Pid}};
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Accept an incoming connection.
%% We let the gen_utp proxy make the accept. When we have a SYN packet an accept
%% cannot fail from there on out, so we can just simply let the proxy to the work for now.
%% There may be some things that changes when you add timeouts to connections.
%% @end
-spec accept() -> {ok, socket()}.
accept() ->
    {ok, _Socket} = call(accept).

%% @doc Send a message on a uTP Socket
%% @end
-spec send(socket(), iolist() | binary() | string()) -> ok | {error, term()}.
send({utp_sock, Pid}, Msg) ->
    gen_utp_worker:send(Pid, iolist_to_binary(Msg)).

-spec send_msg(socket(), term()) -> ok | {error, term()}.
send_msg(Socket, Msg) ->
    EMsg = term_to_binary(Msg, [compressed]),
    Digest = crypto:sha(EMsg),
    Sz = byte_size(EMsg) + byte_size(Digest),
    send(Socket, <<Sz:32/integer, Digest/binary, EMsg/binary>>).

%% @doc Receive a message
%%   The `Length' parameter specifies the size of the data to wait for. Providing a value of
%%   `0' means to fetch all available data. There is currently no provision for timeouts on sockets,
%%   but that will be provided later on.
%% @end
-spec recv(socket(), integer()) ->
                  {ok, binary()} | {error, term()}.
recv({utp_sock, Pid}, Length) when Length >= 0 ->
    gen_utp_worker:recv(Pid, Length).

recv_msg(Socket) ->
    case recv(Socket, 4) of
        {ok, <<Sz:32/integer>>} ->
            case recv(Socket, Sz) of
                {ok, <<Digest:20/binary, EMsg/binary>>} ->
                    Digest = crypto:sha(EMsg),
                    Term = binary_to_term(EMsg, [safe]),
                    {ok, Term};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Close down a socket (nonblocking)
%% @end
close({utp_sock, Pid}) ->
    gen_utp_worker:close(Pid).

%% @doc Listen on socket, with queue length Q
%% @end
-spec listen([listen_opts()]) -> ok | {error, term()}.
listen(Options) ->
    case validate_listen_opts(Options) of
        ok ->
            call({listen, Options});
        badarg ->
            {error, badarg}
    end.

%% @equiv listen(5)
-spec listen() -> ok | {error, term()}.
listen() ->
    listen([{backlog, 5}]).


%% @doc New unknown incoming packet
incoming_unknown(#packet { ty = st_syn } = Packet, Addr, Port) ->
    %% SYN packet, so pass it in
    gen_server:cast(?MODULE, {incoming_syn, Packet, Addr, Port});
incoming_unknown(#packet{ ty = st_reset } = _Packet, _Addr, _Port) ->
    %% Stray RST packet received, ignore since there is no connection for it
    ok;
incoming_unknown(#packet{} = Packet, Addr, Port) ->
    %% Stray, RST it
    utp:report_event(95, us, unknown_packet, [Packet]),
    gen_server:cast(?MODULE, {generate_reset, Packet, Addr, Port}).

%% @doc Register a process as the recipient of a given incoming message
%% @end
register_process(Pid, Conn) ->
    call({reg_proc, Pid, Conn}).

%% @doc Look up the registrar underneath a given connection ID
%% @end
lookup_registrar(CID, Addr, Port) ->
    case ets:lookup(?TAB, {CID, Addr, Port}) of
        [] ->
            not_found;
        [{_, Pid}] ->
            {ok, Pid}
    end.

%% @doc Reply back to a socket user
%% @end
reply(To, Msg) ->
    gen_fsm:reply(To, Msg).

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
init([Port, _Opts]) ->
    {ok, Socket} = gen_udp:open(Port, [binary, {active, once}]),
    ets:new(?TAB, [named_table, protected, set]),
    {ok, #state{ monitored = gb_trees:empty(),
                 listen_queue = closed,
                 socket = Socket }}.

%% @private
handle_call(accept, _From, #state { listen_queue = closed } = S) ->
    {reply, {error, no_listen}, S};
handle_call(accept, From, #state { listen_queue = Q,
                                   listen_options = ListenOpts,
                                   monitored = Monitored,
                                   socket = Socket } = S) ->
    false = Q =:= closed,
    {ok, Pairings, NewQ} = push_acceptor(From, Q),
    N_MonitorTree = pair_acceptors(ListenOpts, Socket, Pairings, Monitored),
    
    {noreply, S#state { listen_queue = NewQ,
                        monitored = N_MonitorTree }};
handle_call({listen, Options}, _From, #state { listen_queue = closed } = S) ->
    QLen = proplists:get_value(backlog, Options),
    {reply, ok, S#state { listen_queue = new_accept_queue(QLen),
                          listen_options = Options }};
handle_call({listen, _QLen}, _From, #state { listen_queue = #accept_queue{} } = S) ->
    {reply, {error, ealreadylistening}, S};
handle_call({reg_proc, Proc, CID}, _From, #state { monitored = Monitored } = State) ->
    Reply = reg_proc(Proc, CID),
    case Reply of
        ok ->
            Ref = erlang:monitor(process, Proc),            
            {reply, ok, State#state { monitored = gb_trees:enter(Ref, CID, Monitored) }};
        {error, Reason} ->
            {reply, {error, Reason}}
    end;
handle_call(get_socket, _From, S) ->
    {reply, {ok, S#state.socket}, S};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

pair_acceptors(ListenOpts, Socket, Pairings, Monitored) ->
    PidsCIDs = [accept_incoming_conn(Socket, Acc, SYN, ListenOpts) || {Acc, SYN} <- Pairings],
    lists:foldl(fun({Pid, CID}, MTree) ->
                        Ref = erlang:monitor(process, Pid),
                        gb_trees:enter(Ref, CID, MTree)
                end,
                Monitored,
                PidsCIDs).

%% @private
handle_cast({incoming_syn, _P, _Addr, _Port}, #state { listen_queue = closed } = S) ->
    %% Not listening on queue
    %% @todo RESET sent back here?
    ?WARN([incoming_syn_but_listen_closed]),
    {noreply, S};
handle_cast({incoming_syn, Packet, Addr, Port}, #state { listen_queue = Q,
                                                         listen_options = ListenOpts,
                                                         monitored = Monitored,
                                                         socket = Socket } = S) ->
    Elem = {Packet, Addr, Port},
    case push_syn(Elem, Q) of
        synq_full ->
            {noreply, S}; % @todo RESET sent back?
        duplicate ->
            {noreply, S};
        {ok, Pairings, NewQ} ->
            N_Monitored = pair_acceptors(ListenOpts, Socket, Pairings, Monitored),
            {noreply, S#state { listen_queue = NewQ,
                                monitored = N_Monitored }}
    end;
handle_cast({generate_reset, #packet { conn_id = ConnID,
                                       seq_no  = SeqNo }, Addr, Port},
            #state { socket = Socket } = State) ->
    {ok, _} = utp_socket:send_reset(Socket, Addr, Port, ConnID, SeqNo,
                                    utp_buffer:mk_random_seq_no()),
    {noreply, State};
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
    {CID, Addr, Port} = gb_trees:get(Ref, MM),
    utp:report_event(95, us, 'DOWN', [{monitored, MM}, {ref, Ref}, {cid, CID}]),
    true = ets:delete(?TAB, {CID, Addr, Port}),
    true = ets:delete(?TAB, {CID+1, Addr, Port}),
    {noreply, S#state { monitored = gb_trees:delete(Ref, MM)}};
handle_info(_Info, State) ->
    ?ERR([unknown_handle_info, _Info, State]),
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
    case queue:member(SYNPacket, IC) of
        true ->
            duplicate;
        false ->
            handle_queue(Q#accept_queue { incoming_conns = queue:in(SYNPacket, IC),
                                          q_len          = QLen + 1 }, [])
    end.


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

accept_incoming_conn(Socket, From, {SynPacket, Addr, Port}, ListenOpts) ->
    {ok, Pid} = gen_utp_worker_pool:start_child(Socket, Addr, Port, ListenOpts),
    %% We should register because we are the ones that can avoid the deadlock here
    %% @todo This call can in principle fail due to a conn_id being in use, but we will
    %% know if that happens.
    CID = {SynPacket#packet.conn_id, Addr, Port},
    case reg_proc(Pid, CID) of
        ok ->
            ok = gen_utp_worker:accept(Pid, SynPacket),
            gen_server:reply(From, {ok, {utp_sock, Pid}}),
            {Pid, CID}
    end.

new_accept_queue(QLen) ->
    #accept_queue { acceptors = queue:new(),
                    incoming_conns = queue:new(),
                    q_len = 0,
                    max_q_len = QLen }.

get_socket() ->
    call(get_socket).

call(Msg) ->
    gen_server:call(?MODULE, Msg, infinity).

reg_proc(Proc, {ConnId, Addr, Port}) ->
    case ets:member(?TAB, {ConnId, Addr, Port})
        orelse ets:member(?TAB, {ConnId+1, Addr, Port})
    of
        true ->
            {error, conn_id_in_use};
        false ->
            true = ets:insert(?TAB, [{{ConnId,   Addr, Port}, Proc},
                                     {{ConnId+1, Addr, Port}, Proc}]),
            ok
    end.

-spec validate_listen_opts([listen_opts()]) -> ok | badarg.
validate_listen_opts([]) ->
    ok;
validate_listen_opts([{backlog, N} | R]) ->
    case is_integer(N) of
        true ->
            validate_listen_opts(R);
        false ->
            badarg
    end;
validate_listen_opts([{force_seq_no, N} | R]) ->
    case is_integer(N) of
        true when N >= 0,
                  N =< 16#FFFF ->
            validate_listen_opts(R);
        true ->
            badarg;
        false ->
            badarg
    end;
validate_listen_opts([{trace_counters, B} | R]) when is_boolean(B) ->
    validate_listen_opts(R);
validate_listen_opts([_U | R]) ->
    validate_listen_opts(R).
