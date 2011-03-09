%% @author Edward Wang <yujiangw@gmail.com>
%% @doc Represents a UPnP device or service.
%% @end

-module(etorrent_upnp_entity).
-behaviour(gen_server).

-include("log.hrl").

-ifdef(TEST).
-include_lib("eqc/include/eqc.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([start_link/2,
         id/2,
         create/2,
         update/2,
         unsubscribe/2,
         notify/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).


-record(state, {cat     :: 'device' | 'service',
                prop    :: etorrent_types:upnp_device() |
                           etorrent_types:upnp_service()}).

-define(SERVER, ?MODULE).
-define(UPNP_RD_NAME, <<"rootdevice">>). %% Literal name of UPnP root device

%%===================================================================
%% API
%%===================================================================
start_link(Cat, Prop) ->
    Args = [{cat, Cat}, {prop, Prop}],
    gen_server:start_link(?MODULE, Args, []).


id(Cat, Prop) ->
    Type = proplists:get_value(type, Prop),
    UUID = proplists:get_value(uuid, Prop),
    _Id = erlang:phash2({Cat, Type, UUID}).


create(Cat, Proplist) ->
    etorrent_upnp_sup:add_upnp_entity(Cat, Proplist).


update(Cat, Prop) ->
    case lookup_pid(Cat, Prop) of
        {ok, Pid} ->
            gen_server:cast(Pid, {update, Cat, Prop});
        {error, not_found} ->
            create(Cat, Prop)
    end.


unsubscribe(Cat, Prop) ->
    case lookup_pid(Cat, Prop) of
        {ok, Pid} ->
            gen_server:cast(Pid, {unsubscribe, Cat, Prop});
        {error, not_found} ->
            do_unsubscribe(Cat, Prop)
    end.
    

%% @todo See explanation in ``etorrent_upnp_httpd''.
-spec notify(etorrent_types:upnp_notify()) -> ok.
notify(_Content) ->
    ok.

%%===================================================================
%% gen_server callbacks
%%===================================================================
init(Args) ->
    %% We trap exits to unsubscribe from UPnP service.
    process_flag(trap_exit, true),
    register_self(Args),
    {ok, #state{cat     = proplists:get_value(cat, Args),
                prop    = proplists:get_value(prop, Args)}, 0}.


handle_call(_Request, _From, State) ->
    {reply, ok, State}.


handle_cast({update, Cat, NewProp}, #state{prop = Prop} = State) ->
    Merged = etorrent_utils:merge_proplists(Prop, NewProp),
    case can_do_port_mapping(Cat, Merged) of
        true ->
            %% add three port mapping for etorrent: listen_port, udp_port,
            %% and dht_port. if etorrent listens on more ports in the future,
            %% simply add them here.
            DHTEnabled = etorrent_config:dht(),
            add_port_mapping(self(), tcp, etorrent_config:listen_port()),
            add_port_mapping(self(), udp, etorrent_config:udp_port()),
            [add_port_mapping(self(), udp, etorrent_config:dht_port()) || DHTEnabled];
        _ -> ignore
    end,
    case can_subscribe(Cat, Merged) of
        true -> subscribe(self());
        _ -> ignore
    end,
    etorrent_table:update_upnp_entity(self(), Cat, Merged),
    {noreply, State#state{prop = Merged}};
handle_cast({unsubscribe, Cat, Prop}, State) ->
    NewProp = do_unsubscribe(Cat, Prop),
    etorrent_table:update_upnp_entity(self(), Cat, NewProp),
    {noreply, State#state{prop = NewProp}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(timeout, State) ->
    %% If root device, retrieves its description.
    #state{cat = Cat, prop = Prop} = State,
    case is_root_device(Cat, Prop) of
        true ->
            etorrent_upnp_net:description(Cat, Prop);
        _ -> ok
    end,
    {noreply, State};
handle_info({add_port_mapping, Proto, Port}, State) ->
    #state{prop = Prop} = State,
    case etorrent_upnp_net:add_port_mapping(Prop, Proto, Port) of
        ok ->
            ?INFO({port_mapping_added, Proto, Port}),
            ?NOTIFY({port_mapping_added, Proto, Port});
        {failed, ErrCode, ErrDesc} ->
            ?INFO({add_port_mapping_failed, Proto, Port, ErrCode, ErrDesc}),
            ?NOTIFY({add_port_mapping_failed, Proto, Port, ErrCode, ErrDesc});
        _ -> ignore
    end,
    {noreply, State};
handle_info(subscribe, State) ->
    #state{cat = Cat, prop = Prop} = State,
    NewProp = case is_subscribed(Prop) of
        false ->
            case etorrent_upnp_net:subscribe(Prop) of
                {ok, Sid} ->
                    etorrent_utils:merge_proplists(Prop, [{sid, Sid}]);
                {error, _} -> Prop
            end;
        true -> Prop
    end,
    etorrent_table:update_upnp_entity(self(), Cat, NewProp),
    {noreply, State#state{prop = NewProp}};
handle_info(Info, State) ->
    ?WARN([unknown_info, Info]),
    {noreply, State}.


terminate(_Reason, State) ->
    #state{cat = Cat, prop = Prop} = State,
    do_unsubscribe(Cat, Prop).


code_change(_OldVer, S, _Extra) ->
    {ok, S}.


%%===================================================================
%% private
%%===================================================================

register_self(Args) ->
    Cat = proplists:get_value(cat, Args),
    Prop = proplists:get_value(prop, Args),
    etorrent_table:register_upnp_entity(self(), Cat, Prop).

lookup_pid(Cat, Prop) ->
    etorrent_table:lookup_upnp_entity(Cat, Prop).


is_root_device(Cat, Prop) ->
    Type = proplists:get_value(type, Prop),
    Cat =:= device andalso Type =:= ?UPNP_RD_NAME.


can_do_port_mapping(Cat, Prop) ->
    Type = proplists:get_value(type, Prop),
    CtlPath = proplists:get_value(ctl_path, Prop),
    Cat =:= service
        andalso CtlPath =/= undefined
        andalso (Type =:= <<"WANIPConnection">>
                 orelse Type =:= <<"WANPPPConnection">>).


add_port_mapping(Pid, Proto, Port) ->
    Pid ! {add_port_mapping, Proto, Port}.


can_subscribe(Cat, Prop) ->
    EventPath = proplists:get_value(event_path, Prop),
    Cat =:= service andalso EventPath =/= undefined.

subscribe(Pid) ->
    Pid ! subscribe.

is_subscribed(Prop) ->
    Sid = proplists:get_value(sid, Prop),
    Sid =/= undefined.

-spec do_unsubscribe(device | service,
                     etorrent_types:upnp_device() | etorrent_types:upnp_service()) ->
                    etorrent_types:upnp_device() | etorrent_types:upnp_service().
do_unsubscribe(Cat, Prop) ->
    NewProp = case Cat of
        service ->
            Sid = proplists:get_value(sid, Prop),
            case Sid of
                undefined -> Prop;
                _ ->
                    etorrent_upnp_net:unsubscribe(Prop),
                    proplists:delete(sid, Prop)
            end;
        _ -> Prop
    end,
    NewProp.

