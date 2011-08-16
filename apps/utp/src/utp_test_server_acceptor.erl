%%% @author Jesper Louis andersen <>
%%% @copyright (C) 2011, Jesper Louis andersen
%%% @doc
%%%   Accept and handle a child connection for the test server
%%% @end
%%% Created : 12 Aug 2011 by Jesper Louis andersen <>
-module(utp_test_server_acceptor).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE). 

-record(state, { socket = none :: none | gen_utp:socket() }).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc
%% Starts the server
%% @end
start_link() ->
    gen_server:start_link(?MODULE, [], []).

%%%===================================================================

%% @private
init([]) ->
    {ok, #state{ }, 0}.

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

%% @private
handle_info(timeout, #state { socket = none} = State) ->
    error_logger:info_report([accepting]),
    case gen_utp:accept() of
        {ok, Sock} ->
            error_logger:info_report([accepted]),
            {ok, _Pid} = utp_test_server_pool_sup:start_child(),
            {noreply, State#state { socket = Sock }, 0}
        %% {error, Something} ->
        %%     error_logger:info_report([accept_error, Something]),
        %%     {ok, _Pid} = utp_test_server_pool_sup:start_child(),
        %%     {stop, normal, State}
    end;
handle_info(timeout, #state { socket = Sock } = State) ->
    %% Read from the socket.
    {ok, Cmd} = gen_utp:recv_msg(Sock),
    case validate_message(Cmd) of
        ok ->
            Res = utp_file_map:cmd(Cmd),
            gen_utp:send_msg(Sock, Res),
            {noreply, State, 0};
        error ->
            error_logger:info_report([invalid_cmd, Cmd]),
            gen_utp:close(Sock),
            {stop, normal, State}
    end;
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

validate_message(ls) ->
    ok;
validate_message({get, _FName}) ->
    ok;
validate_message(_Otherwise) ->
    error.

