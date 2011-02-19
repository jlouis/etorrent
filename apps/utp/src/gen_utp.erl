%%% @author Jesper Louis andersen <jesper.louis.andersen@gmail.com>
%%% @copyright (C) 2011, Jesper Louis andersen
%%% @doc Generic server interface for uTP
%%% @end
-module(gen_utp).

-behaviour(gen_server).

%% API (Supervisor)
-export([start_link/0]).

%% API (Use)
-export([connect/2, connect/3,
	 send/2,
	 recv/2, recv/3,
	 listen/1, accept/1]).

%% Internally used API
-export([register_process/2]).
-export([lookup_registrar/1]).

-type utp_socket() :: {utp_sock, pid()}.
-export_type([utp_socket/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(TAB, ?MODULE).

-record(state, { monitored :: gb_tree() }).

%%%===================================================================

%% @doc Starts the server
%% @end
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @equiv connect(Addr, Port, [])
connect(Addr, Port) ->
    connect(Addr, Port, []).

%% @doc Connect to a foreign uTP peer
%% @end
connect(Addr, Port, Options) ->
    {ok, Pid} = gen_utp_pool:start_child(Addr, Port, Options),
    gen_utp_worker:connect(Pid).

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

listen(_Port) ->
    %% Open a listen socket.
    todo.

accept(_ListenSock) ->
    %% Accept a listen socket.
    todo.

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
init([]) ->
    true = ets:new(?TAB, [named_table, protected, set]),
    {ok, #state{ monitored = gb_trees:new() }}.

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
handle_call({reg_proc, Proc, CID}, _From, State) ->
    true = ets:insert(?TAB, {CID, Proc}),
    Ref = erlang:monitor(process, Proc),
    {reply, ok, State#state { monitored = gb_trees:insert(Ref, CID) }};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({'DOWN', Ref, process, _Pid, _Reason}, #state { monitored = MM } = S) ->
    CID = gb_trees:fetch(Ref, MM),
    true = ets:delete(?TAB, CID),
    {noreply, S#state { monitored = gb_trees:delete(Ref, MM)}};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

call(Msg) ->
    gen_server:call(?MODULE, Msg, infinity).


