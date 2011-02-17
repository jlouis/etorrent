%% @author Edward Wang <yujiangw@gmail.com>
%% @doc Implements a HTTP server for UPnP services to callback into.
%% @end
%%
%% @todo: Use supervisor_bridge instead?
%%        And rename to etorrent_upnp_httpd_sup?
-module(etorrent_upnp_httpd).
-behaviour(gen_server).

-include("log.hrl").


%% API
-export([start_link/0,
         loop/1,
         get_port/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {server :: pid(),
                server_ref :: reference()}).

-define(SERVER, ?MODULE).
-define(HTTPD_NAME, etorrent_upnp_http_server).
-define(LOOP, {?SERVER, loop}).
-define(NOTIFY(M), etorrent_event:notify(M)).

%%===================================================================
%% API
%%===================================================================
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


loop(Req) ->
    %% Don't do the loop in handle_cast/2, mochiweb seems not like it.
    case Req:get(method) of
        "NOTIFY" ->
            ReqBody = Req:recv_body(),
            %% @todo: intention here is to use eventing to monitor if there's
            %%        someone else steals etorrent's port mapping. but seems
            %%        the router used to test against it (linksys srt54g) doesn't
            %%        send out notifition for port mapping. so the port mapping
            %%        protection is yet to be implemented. only the eventing
            %%        subscribe / unsubscribe skeleton is done.
            case etorrent_upnp_proto:parse_notify_msg(ReqBody) of
                undefined -> ignore;
                Content -> etorrent_upnp_entity:notify(Content)
            end,
            Req:ok({"text/plain", [], []});
        _ -> ignore
    end.


get_port() ->
    gen_server:call(?SERVER, {get_port}).

%%===================================================================
%% gen_server callbacks
%%===================================================================
init([]) ->
    {Server, ServerRef} = start_and_monitor_httpd(),
    {ok, #state{server = Server, server_ref = ServerRef}}.

handle_call({get_port}, _From, S) ->
    Port = mochiweb_socket_server:get(S#state.server, port),
    {reply, Port, S};
handle_call(_Request, _From, S) ->
    {reply, ok, S}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', ServerRef, _, _, _}, S) ->
    ?WARN([restarting_httpd]),
    {Server, ServerRef} = start_and_monitor_httpd(),
    {ok, S#state{server = Server, server_ref = ServerRef}};
handle_info(Info, S) ->
    ?WARN([unknown_info, Info]),
    {noreply, S}.

terminate(_Reason, S) ->
    _ = erlang:demonitor(S#state.server_ref),
    mochiweb_http:stop(?HTTPD_NAME).

code_change(_OldVer, State, _Extra) ->
    {ok, State}.

%%===================================================================
%% private
%%===================================================================
start_and_monitor_httpd() ->
    try
        {ok, Server} = mochiweb_http:start([{name, ?HTTPD_NAME}, {loop, ?LOOP}]),
        ServerRef = erlang:monitor(process, Server),
        {Server, ServerRef}
    catch
        error:Err ->
            ?NOTIFY({upnp_httpd_start_error, Err})
    end.

