%%%-------------------------------------------------------------------
%%% @author Jesper Louis andersen <>
%%% @copyright (C) 2011, Jesper Louis andersen
%%% @doc
%%%
%%% @end
%%% Created : 11 Aug 2011 by Jesper Louis andersen <>
%%%-------------------------------------------------------------------
-module(utp_file_map).

-behaviour(gen_server).

%% API
-export([start_link/1,
         cmd/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE). 

-record(state, { file_map :: dict() }).

%%%===================================================================

%% @doc
%% Starts the server
%% @end
%%--------------------------------------------------------------------
start_link(DirToServe) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [DirToServe], []).

cmd(CMD) ->
    call({cmd, CMD}).

%%%===================================================================

%% @private
init([DirToServe]) ->
    FileMap = make_file_map(DirToServe),
    {ok, #state{ file_map = FileMap }}.

%% @private
handle_call({cmd, {get, H}}, _From, #state { file_map = FMap } = State) ->
    case dict:find(H, FMap) of
        error ->
            {reply, {error, not_found}, State};
        {ok, FName} ->
            {reply, {ok, read(FName)}, State}
    end;
handle_call({cmd, ls}, _From, #state { file_map = FMap } = State) ->
    Keys = dict:fetch_keys(FMap),
    {reply, {ok, Keys}, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================

call(X) ->
    gen_server:call(?MODULE, X, infinity).

read(FName) ->
    {ok, Data} = file:read_file(FName),
    Data.

make_file_map(_Dir) ->
    dict:new().










