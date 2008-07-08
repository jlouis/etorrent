%%%-------------------------------------------------------------------
%%% File    : etorrent_event.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Event tracking inside the etorrent application.
%%%
%%% Created : 25 Aug 2007 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_event).

-behaviour(gen_event).
%% API
-export([start_link/0, add_handler/0,
	 started_torrent/1,
	 checking_torrent/1,
	 seeding_torrent/1]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
	 handle_info/2, terminate/2, code_change/3]).

-record(state, {}).

-define(SERVER, ?MODULE).

%%====================================================================
%% gen_event callbacks
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | {error,Error}
%% Description: Creates an event manager.
%%--------------------------------------------------------------------
start_link() ->
    gen_event:start_link({local, ?SERVER}).

%%--------------------------------------------------------------------
%% Function: add_handler() -> ok | {'EXIT',Reason} | term()
%% Description: Adds an event handler
%%--------------------------------------------------------------------
add_handler() ->
    gen_event:add_handler(?SERVER, ?MODULE, []).

started_torrent(Id) ->
    gen_event:notify(?SERVER, {started_torrent, Id}).

checking_torrent(Id) ->
    gen_event:notify(?SERVER, {checking_torrent, Id}).

seeding_torrent(Id) ->
    gen_event:notify(?SERVER, {seeding_torrent, Id}).

%%====================================================================
%% gen_event callbacks
%%====================================================================
%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State}
%% Description: Whenever a new event handler is added to an event manager,
%% this function is called to initialize the event handler.
%%--------------------------------------------------------------------
init([]) ->
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% Function:
%% handle_event(Event, State) -> {ok, State} |
%%                               {swap_handler, Args1, State1, Mod2, Args2} |
%%                               remove_handler
%% Description:Whenever an event manager receives an event sent using
%% gen_event:notify/2 or gen_event:sync_notify/2, this function is called for
%% each installed event handler to handle the event.
%%--------------------------------------------------------------------
handle_event(_Event, State) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Function:
%% handle_call(Request, State) -> {ok, Reply, State} |
%%                                {swap_handler, Reply, Args1, State1,
%%                                  Mod2, Args2} |
%%                                {remove_handler, Reply}
%% Description: Whenever an event manager receives a request sent using
%% gen_event:call/3,4, this function is called for the specified event
%% handler to handle the request.
%%--------------------------------------------------------------------
handle_call(_Request, State) ->
    Reply = ok,
    {ok, Reply, State}.

%%--------------------------------------------------------------------
%% Function:
%% handle_info(Info, State) -> {ok, State} |
%%                             {swap_handler, Args1, State1, Mod2, Args2} |
%%                              remove_handler
%% Description: This function is called for each installed event handler when
%% an event manager receives any other message than an event or a synchronous
%% request (or a system message).
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description:Whenever an event handler is deleted from an event manager,
%% this function is called. It should be the opposite of Module:init/1 and
%% do any necessary cleaning up.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Function: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
