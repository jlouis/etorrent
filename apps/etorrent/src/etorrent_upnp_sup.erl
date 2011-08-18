%% @author Edward Wang <yujiangw@gmail.com>
%% @doc Supervises all processes of UPnP subsystem.
%% @end

-module(etorrent_upnp_sup).
-behaviour(supervisor).

-include("log.hrl").

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([start_link/0,
         add_upnp_entity/2]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    SupName = {local, ?SERVER},
    supervisor:start_link(SupName, ?MODULE, []).

    
init([]) ->
    UPNP_NET = {etorrent_upnp_net, {etorrent_upnp_net, start_link, []},
                permanent, 2000, worker, [etorrent_upnp_net]},
    HTTPd = {etorrent_upnp_httpd, {etorrent_upnp_httpd, start_link, []},
             permanent, 2000, worker, [etorrent_upnp_httpd]},
    Children = [UPNP_NET, HTTPd],
    RestartStrategy = {one_for_one, 1, 60},
    {ok, {RestartStrategy, Children}}.


add_upnp_entity(Category, Proplist) ->
    %% Each UPnP device or service can be uniquely identified by its
    %% category + type + uuid.
    ChildID = {etorrent_upnp_entity, Category,
               proplists:get_value(type, Proplist),
               proplists:get_value(uuid, Proplist)},
    ChildSpec = {ChildID,
                 {etorrent_upnp_entity, start_link, [Category, Proplist]},
                 permanent, 2000, worker, dynamic},
    case supervisor:start_child(?SERVER, ChildSpec) of
        {ok, _} -> ok;
        {error, {already_started, _}} ->
            etorrent_upnp_entity:update(Category, Proplist)
    end.


-ifdef(EUNIT).

setup_upnp_sup_tree() ->
    {event, Event} = {event, etorrent_event:start_link()},
    {table, Table} = {table, etorrent_table:start_link()},
    {upnp,  UPNP}  = {upnp,  etorrent_upnp_sup:start_link()},
    {Event, Table, UPNP}.

teardown_upnp_sup_tree({Event, Table, UPNP}) ->
    Shutdown = fun
        ({ok, Pid}) -> etorrent_utils:shutdown(Pid);
        ({error, Reason}) -> Reason
    end,
    EventStatus = Shutdown(Event),
    TableStatus = Shutdown(Table),
    UPNPStatus  = Shutdown(UPNP),
    ?assertEqual(ok, EventStatus),
    ?assertEqual(ok, TableStatus),
    ?assertEqual(ok, UPNPStatus).

upnp_sup_test_() ->
    {foreach,
        fun setup_upnp_sup_tree/0,
        fun teardown_upnp_sup_tree/1, [
        ?_test(upnp_sup_tree_start_case()),
        ?_test(multiple_instances_case())]}.


upnp_sup_tree_start_case() ->
    etorrent_upnp_entity:create(device, [{type, <<"InternetGatewayDevice">>},
                                         {uuid, <<"whatever">>}]),
    etorrent_upnp_entity:create(service, [{type, <<"WANIPConnection">>},
                                          {uuid, <<"whatever">>}]),
    etorrent_upnp_entity:update(service, [{type, <<"WANIPConnection">>},
                                          {uuid, <<"whatever">>},
                                          {loc, {192,168,1,1}}]),
    ?assert(true).


multiple_instances_case() ->
    %% may need to run multiple instances, e.g. when doing test. make sure
    %% embeded mochiweb http server will not conflict with each other in
    %% that case.
    %% simulates parallel run by starting another (default) mochiweb server 
    {ok, _Server} = mochiweb_http:start([{name, multiple_instances_test},
                                         {loop, {mochiweb_http, default_body}}]),
    ?assert(true).


%% @todo: Can do way more unit tests here.

-endif.

