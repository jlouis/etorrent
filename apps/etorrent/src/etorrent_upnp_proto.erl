%% @author Edward Wang <yujiangw@gmail.com>
%%
%% @doc Utilities to manipulate UPnP wire message, such as parsing
%%      M-SEARCH response, parsing device description, and assembling
%%      action control message.
%% @end

-module(etorrent_upnp_proto).

-include_lib("xmerl/include/xmerl.hrl").

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(UPNP_RD_NAME, <<"rootdevice">>). %% Literal name of UPnP root device

%% API
-export([parse_msearch_resp/1,
         parse_description/2,
         build_ctl_msg/3,
         parse_ctl_err_resp/1,
         parse_sub_resp/1,
         guess_sub_resp/1,
         parse_notify_msg/1]).

%% @doc Parse UPnP device's response to M-SEARCH request.
%%
%%      The response is an HTTP one with empty body:
%%      ```
%%      HTTP/1.1 200 OK
%%      CACHE-CONTROL: max-age = seconds until advertisement expires
%%      DATE: when response was generated
%%      EXT:
%%      LOCATION: URL for UPnP description for root device
%%      SERVER: OS/version UPnP/1.0 product/version
%%      ST: search target
%%      USN: advertisement UUID'''
%% @end
-spec parse_msearch_resp(string()) -> {ok, device,  etorrent_types:upnp_device()}
                                    | {ok, service, etorrent_types:upnp_service()}
                                    | {ok, uuid}
                                    | {error, _Reason}.
parse_msearch_resp(Resp) ->
    %% Only interested in headers, strips off first line of the response.
    {ok, _, H} = erlang:decode_packet(http, list_to_binary(Resp), []),
    case parse_headers(H) of
        Headers when is_list(Headers) ->
            Age = parse_max_age(Headers),
            Loc = get_header(<<"LOCATION">>, Headers),
            Svr = get_header(<<"SERVER">>, Headers),
            ST  = get_header(<<"ST">>, Headers),
            {Cat, Type, Ver} = case re:split(binary_to_list(ST), ":", [{return, binary}]) of
                                   [_, _, C, T, V] -> {C, T, V};
                                   [<<"upnp">>, ?UPNP_RD_NAME] -> {<<"device">>, ?UPNP_RD_NAME, <<>>};
                                   [<<"uuid">>, _] -> {<<"uuid">>, <<>>, <<>>}
                               end,
            USN = get_header(<<"USN">>, Headers),
            [_, UUID|_] = re:split(binary_to_list(USN), ":", [{return, binary}]),
            case Cat of
                <<"device">> ->
                    {ok, device, [{type,    Type},
                                  {ver,     Ver},
                                  {uuid,    UUID},
                                  {loc,     Loc},
                                  {max_age, Age},
                                  {server,  Svr}]};
                <<"service">> ->
                    {ok, service, [{type,   Type},
                                   {ver,    Ver},
                                   {uuid,   UUID},
                                   {loc,    Loc}]};
                <<"uuid">> ->
                    {ok, uuid}
            end
    end.

parse_max_age(Headers) ->
    case get_header(<<"CACHE-CONTROL">>, Headers) of
        <<"max-age = ", A/binary>> ->
            list_to_integer(binary_to_list(A))
    end.

get_header(Ty, H) ->
    case lists:keyfind(Ty, 1, H) of
        {_, V} -> V
    end.

%% @doc Parses given description of a UPnP device.
%%
%%      Besides of information of its embeded devices and services,
%%      each device node has format:
%%      ```
%%      <deviceType>urn:schemas-upnp-org:device:deviceType:v</deviceType>
%%      <friendlyName>short user-friendly title</friendlyName>
%%      <manufacturer>manufacturer name</manufacturer>
%%      <manufacturerURL>URL to manufacturer site</manufacturerURL>
%%      <modelDescription>long user-friendly title</modelDescription>
%%      <modelName>model name</modelName>
%%      <modelNumber>model number</modelNumber>
%%      <modelURL>URL to model site</modelURL>
%%      <serialNumber>manufacturer's serial number</serialNumber>
%%      <UDN>uuid:UUID</UDN>
%%      <UPC>Universal Product Code</UPC>'''
%%
%%      While each service node has format:
%%      ```
%%      <service>
%%          <serviceType>urn:schemas-upnp-org:service:serviceType:v</serviceType>
%%          <serviceId>urn:upnp-org:serviceId:serviceID</serviceId>
%%          <SCPDURL>URL to service description</SCPDURL>
%%          <controlURL>URL for control</controlURL>
%%          <eventSubURL>URL for eventing</eventSubURL>
%%      </service>'''
%% @end
-spec parse_description(inet:ip_address(), string())
        -> {ok, [etorrent_types:upnp_device()],
                [etorrent_types:upnp_service()]} | {error, _Reason}.
parse_description(LocalAddr, Desc) ->
    try
        {Xml, _} = xmerl_scan:string(Desc, [{space, normalize}]),
        DS = xmerl_xpath:string("//device", Xml),
        {Devices, Services} = ll_parse_desc(LocalAddr, DS, {[], []}),
        {ok, Devices, Services}
    catch
        error:Reason -> {error, Reason}
    end.

ll_parse_desc(_LocalAddr, [], {DAcc, SAcc}) ->
    {lists:reverse(DAcc), SAcc};
ll_parse_desc(LocalAddr, DS, {DAcc, SAcc}) ->
    try
        [D|Rest] = DS,
        Device = parse_device_desc(LocalAddr, D),
        %% Only extract direct child services of current device
        SS = xmerl_xpath:string("serviceList/service", D),
        Services = [begin
            %% In description message, a UPnP service doesn't have its own UUID.
            %% It inherits one from its enclosing device. But in discovery response
            %% message, a service does have its own, although the same, UUID.
            %% UPnP spec seems to like making random design decisions like this.
            parse_service_desc(LocalAddr, proplists:get_value(uuid, Device), S)
        end || S <- SS],
        ll_parse_desc(LocalAddr, Rest, {[Device|DAcc], lists:append(SAcc, Services)})
    catch
        error:Reason -> throw({error, Reason})
    end.
    

-spec parse_device_desc(inet:ip_address(), term()) -> etorrent_types:upnp_device().
parse_device_desc(LocalAddr, Desc) ->
    T = extract_xml_text(xmerl_xpath:string("deviceType/text()", Desc)),
    [_, _, _, Type|_] = re:split(T, ":", [{return, binary}]),
    UDN = xmerl_xpath:string("UDN/text()", Desc),
    "uuid:" ++ UUID = extract_xml_text(UDN),
    DName = extract_xml_text(xmerl_xpath:string("friendlyName/text()", Desc)),
    DVendor = extract_xml_text(xmerl_xpath:string("manufacturer/text()", Desc)),
    [proplists:property(type,           Type),
     proplists:property(uuid,           list_to_binary(UUID)),
     proplists:property(long_name,      list_to_binary(DName)),
     proplists:property(manufacturer,   list_to_binary(DVendor)),
     proplists:property(local_addr,     LocalAddr)].


-spec parse_service_desc(inet:ip_address(), binary(), string()) ->
                                etorrent_types:upnp_service().
parse_service_desc(LocalAddr, UUID, Desc) ->
    [T, SUrl, CUrl, EUrl] = [begin
        N = xmerl_xpath:string(U ++ "/text()", Desc),
        extract_xml_text(N)
    end || U <- ["serviceType", "SCPDURL", "controlURL", "eventSubURL"]],
    [_, _, _, Type|_] = re:split(T, ":", [{return, binary}]),
    [proplists:property(type, Type),
     proplists:property(uuid, UUID),
     proplists:property(scpd_path, list_to_binary(SUrl)),
     proplists:property(ctl_path, list_to_binary(CUrl)),
     proplists:property(event_path, list_to_binary(EUrl)),
     proplists:property(local_addr, LocalAddr)].


%% @doc Given service, action name and its arguments, assemble a UPnP
%%      control message body.
%%
%%      According to UPnP Device Architecture 1.0 spec section 3.2,
%%      "Control: Action", a control invocation message is a HTTP one with
%%      following SOAP as its body:
%%
%%      ```
%%      <?xml version="1.0"?>
%%      <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
%%                  s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
%%      <s:Body>
%%          <u:actionName xmlns:u="urn:schemas-upnp-org:service:serviceType:v">
%%              <argumentName>in arg value</argumentName>
%%              other in args and their values go here, if any
%%          </u:actionName>
%%      </s:Body>
%%      </s:Envelope>'''
%% @end
-spec build_ctl_msg(etorrent_types:upnp_service(), string(), [{string(), string()}]) -> string().
build_ctl_msg(S, Action, Args) ->
    %% Die, SOAP, die.
    MHdr = "<?xml version=\"1.0\"?>"
            "<s:Envelope"
                " xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\""
                " s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            "<s:Body>",
    MFooter = "</s:Body></s:Envelope>",
    MAHdr = lists:append(["<u:", Action,
                          " xmlns:u=\"urn:schemas-upnp-org:service:",
                          binary_to_list(proplists:get_value(type, S)), ":",
                          binary_to_list(proplists:get_value(ver, S)), "\">"]),
    MArgs = [lists:append(["<", ArgN, ">", ArgV, "</", ArgN, ">"])
             || {ArgN, ArgV} <- Args],
    MAFooter = lists:append(["</u:", Action, ">"]),
    lists:append([MHdr, MAHdr, lists:append(MArgs), MAFooter, MFooter]).


%% @doc If UPnP service encounters error while executing the action sent by
%%      control point, the service sends back an error message. This function
%%      parses the error message and returns error code and description.
%%
%%      According to UPnP Device Architecture 1.0 spec section 3.2, the error
%%      message has following format:
%%      ```
%%      <?xml version="1.0"?>
%%      <s:Envelope
%%          xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
%%          s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
%%          <s:Body>
%%              <s:Fault>
%%                  <faultcode>s:Client</faultcode>
%%                  <faultstring>UPnPError</faultstring>
%%                  <detail>
%%                      <UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
%%                      <errorCode>error code</errorCode>
%%                      <errorDescription>error string</errorDescription>
%%                      </UPnPError>
%%                  </detail>
%%              </s:Fault>
%%          </s:Body>
%%      </s:Envelope>'''
%% @end
-spec parse_ctl_err_resp(string()) -> {integer(), string()}.
parse_ctl_err_resp(Resp) ->
    {Xml, _} = xmerl_scan:string(Resp),
    C = xmerl_xpath:string("//errorCode/text()", Xml),
    {ECode, _} = string:to_integer(extract_xml_text(C)),
    D = xmerl_xpath:string("//errorDescription/text()", Xml),
    EDesc = extract_xml_text(D),
    {ECode, EDesc}.


%% @doc Parse headers, quick'n'dirty variant
-define(CRLF, "\r\n").
parse_headers(Bin) ->
    Lines = binary:split(Bin, <<?CRLF>>, [global, trim]),
    [begin
         case binary:split(L, <<": ">>, [trim]) of
             [Key, Value] -> {Key, Value};
             Key -> {Key}
         end
     end || L <- Lines].
%%
%% @doc Parses UPnP service's response to our subscription request,
%%      returns subscription id if succeeded. Or undefined if failed.
%% @end
%%
-spec parse_sub_resp(term()) -> string() | undefined.
parse_sub_resp(Resp) ->
    
    Headers = parse_headers(Resp),
    case lists:keyfind(<<"SID">>, 1, Headers) of
        false -> undefined;
        {_Key, <<"uuid:", Sid/binary>>} ->
            binary_to_list(Sid)
    end.

%%
%% @doc Guesses what's in malformed subscription response.
%%
-spec guess_sub_resp(term()) -> string() | undefined.
guess_sub_resp(Resp) ->
    {ok, _, H} = erlang:decode_packet(http, Resp, []),
    Sid = parse_sub_resp(H),
    Sid.


%% @doc Parses UPnP eventing notify message.
%%
%%      4.2.1
%%      ```
%%      <?xml version="1.0"?>
%%      <e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">
%%          <e:property>
%%              <variableName>new value</variableName>
%%          </e:property>
%%          Other variable names and values (if any) go here.
%%      </e:propertyset>
%%      '''
%% @end
%% @todo See the explanation in ``etorrent_upnp_httpd''.
-spec parse_notify_msg(binary()) -> undefined.
parse_notify_msg(_Msg) ->
    undefined.

%%===================================================================
%% private
%%===================================================================

%% Given a xml text node, extract its text value.
extract_xml_text(Xml) ->
    [T|_] = [X#xmlText.value || X <- Xml, is_record(X, xmlText)],
    T.


%%
%% Unit tests
%%
-ifdef(EUNIT).

wrt54g_discover_test() ->
    %% Those are real responses from a Linksys WRT54G
    Resps = ["HTTP/1.1 200 OK\r\n"
            "CACHE-CONTROL: max-age = 126\r\n"
            "EXT:\r\n"
            "LOCATION: http://192.168.1.1:2869/IGatewayDeviceDescDoc\r\n"
            "SERVER: VxWorks/5.4.2 UPnP/1.0 iGateway/1.1\r\n"
            "ST: upnp:rootdevice\r\n"
            "USN: uuid:B9AE88EA-0D56-49EF-A178-AA9CC8F15656::upnp:rootdevice\r\n\r\n",

            "HTTP/1.1 200 OK\r\n"
            "CACHE-CONTROL: max-age = 126\r\n"
            "EXT:\r\n"
            "LOCATION: http://192.168.1.1:2869/IGatewayDeviceDescDoc\r\n"
            "SERVER: VxWorks/5.4.2 UPnP/1.0 iGateway/1.1\r\n"
            "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n"
            "USN: uuid:B9AE88EA-0D56-49EF-A178-AA9CC8F15656::urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n",

            "HTTP/1.1 200 OK\r\n"
            "CACHE-CONTROL: max-age = 126\r\n"
            "EXT:\r\n"
            "LOCATION: http://192.168.1.1:2869/IGatewayDeviceDescDoc\r\n"
            "SERVER: VxWorks/5.4.2 UPnP/1.0 iGateway/1.1\r\n"
            "ST: uuid:B9AE88EA-0D56-49EF-A178-AA9CC8F15656\r\n"
            "USN: uuid:B9AE88EA-0D56-49EF-A178-AA9CC8F15656\r\n\r\n",

            "HTTP/1.1 200 OK\r\n"
            "CACHE-CONTROL: max-age = 126\r\n"
            "EXT:\r\n"
            "LOCATION: http://192.168.1.1:2869/IGatewayDeviceDescDoc\r\n"
            "SERVER: VxWorks/5.4.2 UPnP/1.0 iGateway/1.1\r\n"
            "ST: urn:schemas-upnp-org:service:Layer3Forwarding:1\r\n"
            "USN: uuid:B9AE88EA-0D56-49EF-A178-AA9CC8F15656::urn:schemas-upnp-org:service:Layer3Forwarding:1\r\n\r\n"],
    Expected = [[{type, <<"rootdevice">>},
                 {ver, <<>>},
                 {uuid, <<"B9AE88EA-0D56-49EF-A178-AA9CC8F15656">>},
                 {loc, <<"http://192.168.1.1:2869/IGatewayDeviceDescDoc">>},
                 {max_age, 126},
                 {server, <<"VxWorks/5.4.2 UPnP/1.0 iGateway/1.1">>}],
                [{type, <<"InternetGatewayDevice">>},
                 {ver, <<"1">>},
                 {uuid, <<"B9AE88EA-0D56-49EF-A178-AA9CC8F15656">>},
                 {loc, <<"http://192.168.1.1:2869/IGatewayDeviceDescDoc">>},
                 {max_age, 126},
                 {server, <<"VxWorks/5.4.2 UPnP/1.0 iGateway/1.1">>}],
                [{type, <<"Layer3Forwarding">>},
                 {ver, <<"1">>},
                 {uuid, <<"B9AE88EA-0D56-49EF-A178-AA9CC8F15656">>},
                 {loc, <<"http://192.168.1.1:2869/IGatewayDeviceDescDoc">>}]],
    Parsed = [D || {ok, _, D} <- lists:map(fun parse_msearch_resp/1, Resps)],
    ?assertEqual(Expected, Parsed).


wrt54g_description_test() ->
    %% This id the description returned from a Linksys WRT54G.
    Desc = "<?xml version=\"1.0\"?>"
            "<root xmlns=\"urn:schemas-upnp-org:device-1-0\">"
                "\t<specVersion>"
                    "\t\t<major>1</major>"
                    "\t\t<minor>0</minor>"
                "\t</specVersion>"
                "\t<device>"
                    "\t\t<deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>"
                    "\t\t<friendlyName>WRT54G</friendlyName>"
                    "\t\t<manufacturer>Linksys</manufacturer>"
                    "\t\t<manufacturerURL>http://www.linksys.com/</manufacturerURL>"
                    "\t\t  \t<modelDescription>WRT54G</modelDescription>   "
                    "\t       \t<modelName>WRT54G</modelName>"
                    "\t\t  \t<modelNumber>WRT54G-01</modelNumber>"
                    "\t\t  \t<modelURL>http://www.linksys.com/</modelURL>"
                    "\t\t  \t<serialNumber>A0001</serialNumber>"
                    "\t\t<UDN>uuid:B9AE88EA-0D56-49EF-A178-AA9CC8F15656</UDN>       "
                    "\t  \t<UPC>IGateway-01</UPC>"
                    "\t\t<iconList>"
                    "\t\t  <icon>"
                    "\t\t  \t<mimetype>image/gif</mimetype>"
                    "\t\t  \t<width>118</width>"
                    "\t\t  \t<height>119</height>"
                    "\t\t  \t<depth>8</depth>"
                    "\t\t  \t<url>/intoto.GIF</url>"
                    "\t\t  </icon>"
                    "\t\t</iconList>"
                    "\t\t<serviceList>"
                    "\t\t  <service>"
                    "            <serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType>"
                    "            <serviceId>urn:upnp-org:serviceId:L3Forwarding1</serviceId>"
                    "            <SCPDURL>/L3ForwardingDescDoc</SCPDURL>"
                    "            <controlURL>/L3ForwardingCtrlUrl</controlURL>"
                    "            <eventSubURL>/L3ForwardingEvtUrl</eventSubURL>"
                    "\t\t  </service>"
                    "\t\t</serviceList>"
                    "\t\t<deviceList>"
                    "\t\t  <device>"
                    "\t\t  \t<deviceType>urn:schemas-upnp-org:device:WANDevice:1</deviceType>"
                    "\t\t  \t<friendlyName>WANDevice</friendlyName>"
                    "\t\t  \t<manufacturer>Linksys</manufacturer>"
                    "\t\t  \t<manufacturerURL>http://www.linksys.com/</manufacturerURL>"
                    "\t\t  \t<modelDescription>WRT54G</modelDescription>"
                    "\t\t  \t<modelName>WRT54G</modelName>"
                    "\t\t  \t<modelNumber>WRT54G-01</modelNumber>"
                    "\t\t  \t<modelURL>http://www.linksys.com/</modelURL>"
                    "\t\t  \t<serialNumber>A0006</serialNumber>"
                    "\t\t\t<UDN>uuid:6A55E32D-646D-4D39-89A2-627F82DD7999</UDN>"
                    "\t\t  \t<UPC>IGateway-01</UPC>"
                    "\t\t  \t<serviceList>"
                    "\t\t    \t<service>"
                    "\t\t\t\t\t<serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType>"
                    "\t\t\t\t\t<serviceId>urn:upnp-org:serviceId:WANCommonIFC1</serviceId>"
                    "\t\t\t\t\t<controlURL>/WANCommonIFCCntrlUrl</controlURL>"
                    "\t\t\t\t\t<eventSubURL>/WANCommonIFCEvtUrl</eventSubURL>"
                    "\t\t\t\t\t<SCPDURL>/WanCommonIFCDescDoc</SCPDURL>"
                    "\t\t\t\t</service>"
                    "\t\t\t</serviceList>"
                    "\t\t\t\t<deviceList>"
                            "<device>"
                    "\t\t\t\t\t<deviceType>urn:schemas-upnp-org:device:WANConnectionDevice:1</deviceType>"
                                "<friendlyName>WANConnectionDevice1</friendlyName>"
                                "<manufacturer>Linksys</manufacturer>"
                        "\t\t\t\t\t<manufacturerURL>http://www.linksys.com/</manufacturerURL>"
                        "\t\t\t\t\t<modelDescription>WRT54G</modelDescription>"
                        "\t\t\t\t\t<modelName>WRT54G</modelName>"
                        "\t\t\t\t\t<modelNumber>WRT54G-01</modelNumber>"
                        "\t\t\t\t\t<modelURL>http://www.linksys.com/</modelURL>"
                        "\t\t\t\t\t<serialNumber>A0006</serialNumber>"
                                    "<UDN>uuid:9709A398-04F5-4ACE-927E-9C79E7434897</UDN>"
                                    "<UPC>IGateway-01</UPC>"
                                    "   <serviceList>"
                                    "   <service>"
                                        "<serviceType>urn:schemas-upnp-org:service:WANEthernetLinkConfig:1</serviceType>"
                                        "<serviceId>urn:upnp-org:serviceId:WANEthernetLinkC1</serviceId>"
                                        "<controlURL>/WANEthernetLinkCfgUrl</controlURL>"
                                        "     <eventSubURL>/WANEthernetLinkCfgUrl</eventSubURL>"
                                        "     <SCPDURL>/WanEthernetLinkCfgDescDoc</SCPDURL>"
                                    "     </service>"
                                    "   <service>"
                                        "<serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>"
                                        "<serviceId>urn:upnp-org:serviceId:WANIPConn1</serviceId>"
                                        "<controlURL>/WANIPConnCtrlUrl</controlURL>"
                                        "\t<eventSubURL>/WANIPConnEvtUrl</eventSubURL>"
                                        "\t<SCPDURL>/WanIPConnectionDescDoc</SCPDURL>"
                                    "</service>"
                                    "\t</serviceList>"
                        "     </device>"
                    "\n\t\t\t\t</deviceList>"
                    "\t\t\t</device>"
                    "\t\t</deviceList>"
                    "\t<presentationURL>http://192.168.1.1:80/</presentationURL>"
                    "\t</device>"
                    "</root>",
    ExpectedD = [[{type, <<"InternetGatewayDevice">>},
                  {uuid, <<"B9AE88EA-0D56-49EF-A178-AA9CC8F15656">>},
                  {long_name, <<"WRT54G">>},
                  {manufacturer, <<"Linksys">>},
                  {local_addr,undefined}],
                 [{type, <<"WANDevice">>},
                  {uuid, <<"6A55E32D-646D-4D39-89A2-627F82DD7999">>},
                  {long_name, <<"WANDevice">>},
                  {manufacturer, <<"Linksys">>},
                  {local_addr,undefined}],
                 [{type, <<"WANConnectionDevice">>},
                  {uuid, <<"9709A398-04F5-4ACE-927E-9C79E7434897">>},
                  {long_name, <<"WANConnectionDevice1">>},
                  {manufacturer, <<"Linksys">>},
                  {local_addr,undefined}]],
    ExpectedS = [[{type, <<"Layer3Forwarding">>},
                  {uuid, <<"B9AE88EA-0D56-49EF-A178-AA9CC8F15656">>},
                  {scpd_path, <<"/L3ForwardingDescDoc">>},
                  {ctl_path, <<"/L3ForwardingCtrlUrl">>},
                  {event_path, <<"/L3ForwardingEvtUrl">>},
                  {local_addr,undefined}],
                 [{type, <<"WANCommonInterfaceConfig">>},
                  {uuid, <<"6A55E32D-646D-4D39-89A2-627F82DD7999">>},
                  {scpd_path, <<"/WanCommonIFCDescDoc">>},
                  {ctl_path, <<"/WANCommonIFCCntrlUrl">>},
                  {event_path, <<"/WANCommonIFCEvtUrl">>},
                  {local_addr,undefined}],
                 [{type, <<"WANEthernetLinkConfig">>},
                  {uuid, <<"9709A398-04F5-4ACE-927E-9C79E7434897">>},
                  {scpd_path, <<"/WanEthernetLinkCfgDescDoc">>},
                  {ctl_path, <<"/WANEthernetLinkCfgUrl">>},
                  {event_path, <<"/WANEthernetLinkCfgUrl">>},
                  {local_addr,undefined}],
                 [{type, <<"WANIPConnection">>},
                  {uuid, <<"9709A398-04F5-4ACE-927E-9C79E7434897">>},
                  {scpd_path, <<"/WanIPConnectionDescDoc">>},
                  {ctl_path, <<"/WANIPConnCtrlUrl">>},
                  {event_path, <<"/WANIPConnEvtUrl">>},
                  {local_addr,undefined}]
               ],
    {ok, Devices, Services} = parse_description(_LocalAddr = undefined, Desc),
    ?assertEqual(ExpectedD, Devices),
    ?assertEqual(ExpectedS, Services).


wrt54g_ctl_err_msg_test() ->
    ErrMsg = "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\""
             " s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
             "<s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>"
             "<detail><UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\">"
             "<errorCode>600</errorCode>"
             "<errorDescription>Argument Value Invalid</errorDescription>"
             "</UPnPError></detail></s:Fault>"
             "</s:Body></s:Envelope>",
    {C, D} = parse_ctl_err_resp(ErrMsg),
    ?assertEqual(C, 600),
    ?assertEqual(D, "Argument Value Invalid").


wrt54g_sub_resp_test() ->
    Resp = <<"HTTP/1.1 200 OK\r\n"
             "SERVER: VxWorks/5.4.2 UPnP/1.0 iGateway/1.1\r\n"
             "SID: uuid:3ee9f315-783a-92cd-8249-00212964c472\r\n"
             "TIMEOUT: Second-0">>,
    Sid = guess_sub_resp(Resp),
    ?assertEqual(Sid, "3ee9f315-783a-92cd-8249-00212964c472").


-endif.

